///|
fn fields(
  value : Json,
  allowed : Array[String],
  path : String,
) -> Map[String, Json] raise StitchError {
  guard value is Object(obj) else { raise Invalid(path + ": expected object") }
  for key in obj.keys() {
    if !allowed.contains(key) {
      raise Invalid(path + ": unsupported field " + key)
    }
  }
  obj
}

///|
fn required(obj : Map[String, Json], key : String) -> Json raise StitchError {
  guard obj.get(key) is Some(value) else { raise Invalid("missing " + key) }
  value
}

///|
fn decimal(value : Json, path : String) -> Int64 raise StitchError {
  guard value is String(text) && !text.is_empty() else {
    raise Invalid(path + ": expected decimal string")
  }
  for ch in text.to_array() {
    if ch < '0' || ch > '9' {
      raise Invalid(path + ": expected unsigned decimal digits")
    }
  }
  @string.parse_int64(text[:], base=10) catch {
    _ => raise Invalid(path + ": exceeds Int64 range")
  }
}

///|
/// Serialize exact decimal values in sorted series order, independent of arrival order.
pub fn State::checkpoint(self : State) -> Json {
  let records = self.records.copy()
  records.sort_by((a, b) => a.last.series.compare(b.last.series))
  {
    "version": 1,
    "max_series": Json(self.limit.to_string()),
    "records": Json::array(
      records.map(r => {
        "series": Json(r.last.series),
        "start": Json(r.last.start.to_string()),
        "end": Json(r.last.end.to_string()),
        "delta": Json(r.last.value.to_string()),
        "origin": Json(r.origin.to_string()),
        "total": Json(r.total.to_string()),
      }),
    ),
  }
}

///|
/// Validate a versioned checkpoint before constructing state. This checks
/// structural consistency, not authenticity of externally modified totals.
pub fn State::restore(value : Json) -> State raise StitchError {
  let obj = fields(value, ["version", "max_series", "records"], "checkpoint")
  if required(obj, "version") != Json(1) {
    raise Invalid("unsupported checkpoint version")
  }
  let limit = decimal(required(obj, "max_series"), "max_series")
  if limit > 100000L {
    raise Invalid("max_series exceeds 100000")
  }
  let state = State::new(max_series=limit.to_int())
  guard required(obj, "records") is Array(items) else {
    raise Invalid("records must be an array")
  }
  if items.length() > state.limit {
    raise Invalid("checkpoint exceeds series limit")
  }
  let records = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let r = fields(
      item,
      ["series", "start", "end", "delta", "origin", "total"],
      "record",
    )
    guard required(r, "series") is String(series) else {
      raise Invalid("series must be a string")
    }
    if seen.contains(series) {
      raise Invalid("duplicate checkpoint series")
    }
    seen[series] = true
    let last : Sample = {
      series,
      start: decimal(required(r, "start"), "start"),
      end: decimal(required(r, "end"), "end"),
      value: decimal(required(r, "delta"), "delta"),
    }
    ignore(state.apply([last]))
    let origin = decimal(required(r, "origin"), "origin")
    let total = decimal(required(r, "total"), "total")
    if origin <= 0L ||
      origin > last.start ||
      total < last.value ||
      (origin == last.start && total != last.value) {
      raise Invalid("checkpoint origin or total contradicts the last delta")
    }
    records.push({ last, origin, total, })
  }
  { records, limit: state.limit, }
}
