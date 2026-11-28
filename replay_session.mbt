///|
/// Serial ordered replay state. A restored session consumes a continuation,
/// never an automatically skipped prefix of the original input file.
pub struct ReplaySession {
  priv current : State
  priv records : Int64
}

///|
pub(all) struct ReplayRecord {
  session : ReplaySession
  request : Json
  duplicates : Int32
  ordinal : Int64
}

///|
pub fn ReplaySession::new(state : State) -> ReplaySession raise StitchError {
  let session : ReplaySession = { current: state, records: 0L, }
  ignore(parse_input(session.checkpoint().stringify()))
  session
}

///|
pub fn ReplaySession::state(self : ReplaySession) -> State {
  self.current
}

///|
pub fn ReplaySession::record_count(self : ReplaySession) -> Int64 {
  self.records
}

///|
pub fn ReplaySession::checkpoint(self : ReplaySession) -> Json {
  {
    "version": 1,
    "records": Json(self.records.to_string()),
    "state": self.current.checkpoint(),
  }
}

///|
pub fn ReplaySession::restore(value : Json) -> ReplaySession raise StitchError {
  let owned = parse_input(value.stringify())
  let obj = fields(owned, ["version", "records", "state"], "replay session")
  if required(obj, "version") != Json(1) {
    raise Invalid("unsupported replay session version")
  }
  {
    current: State::restore(required(obj, "state")),
    records: decimal(required(obj, "records"), "records"),
  }
}

///|
/// Apply one standard Delta OTLP JSON record atomically. Blank/malformed records
/// are refused with a one-based ordinal; no record is silently skipped.
///
/// ```mbt check
/// test {
///   let s = @metricstitch.ReplaySession::new(@metricstitch.State::new())
///   let r = s.apply_line("{\"resourceMetrics\":[]}")
///   assert_eq(r.ordinal, 1L)
///   assert_eq(s.record_count(), 0L)
/// }
/// ```
pub fn ReplaySession::apply_line(
  self : ReplaySession,
  line : String,
) -> ReplayRecord raise StitchError {
  if self.records == 9223372036854775807L {
    raise Invalid("replay record ordinal overflow")
  }
  let ordinal = self.records + 1L
  let result = try {
    if line.contains("\n") || line.contains("\r") {
      raise Invalid("expected one physical JSON record")
    }
    if line.trim().is_empty() {
      raise Invalid("blank NDJSON records are not supported")
    }
    process_otlp(self.current, parse_input(line))
  } catch {
    Invalid(message) =>
      raise Invalid("/records/" + ordinal.to_string() + ": " + message)
  }
  let record : ReplayRecord = {
    session: { current: result.state, records: ordinal, },
    request: result.request,
    duplicates: result.duplicates,
    ordinal,
  }
  ignore(parse_input(record.receipt().stringify()))
  record
}

///|
pub fn ReplayRecord::receipt(self : ReplayRecord) -> Json {
  {
    "session": self.session.checkpoint(),
    "ordinal": Json(self.ordinal.to_string()),
    "duplicates": Json(self.duplicates),
    "request": detached_json(self.request),
  }
}

///|
/// Validate a trusted local record envelope, output profile and ordinal/session
/// consistency. This is not authentication or proof of input-file identity.
pub fn decode_replay_record(value : Json) -> ReplayRecord raise StitchError {
  let owned = parse_input(value.stringify())
  let obj = fields(
    owned,
    ["session", "ordinal", "duplicates", "request"],
    "replay record",
  )
  let session = ReplaySession::restore(required(obj, "session"))
  let ordinal = decimal(required(obj, "ordinal"), "ordinal")
  if ordinal <= 0L || ordinal != session.records {
    raise Invalid("replay ordinal differs from session progress")
  }
  let checked = decode_receipt({
    "checkpoint": session.current.checkpoint(),
    "duplicates": required(obj, "duplicates"),
    "request": required(obj, "request"),
  })
  {
    session,
    ordinal,
    request: checked.request,
    duplicates: checked.duplicates,
  }
}
