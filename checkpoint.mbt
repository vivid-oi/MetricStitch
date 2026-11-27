///|
fn fields(
  value : Json,
  allowed : Array[String],
  path : String,
  issue~ : Ref[IssueCode] = Ref(InvalidInput),
) -> Map[String, Json] raise StitchError {
  guard value is Object(obj) else { raise Invalid(path + ": expected object") }
  for key in obj.keys() {
    if !allowed.contains(key) {
      issue.val = UnsupportedData
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
  let base : Json = {
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
  if self.doubles.is_empty() &&
    self.histograms.is_empty() &&
    self.exponentials.is_empty() {
    return base
  }
  let doubles = self.doubles.copy()
  doubles.sort_by((a, b) => a.last.series.compare(b.last.series))
  guard base is Object(obj) else { abort("checkpoint construction") }
  obj["version"] = Json(2)
  obj["doubles"] = Json::array(
    doubles.map(r => {
      "series": Json(r.last.series),
      "start": Json(r.last.start.to_string()),
      "end": Json(r.last.end.to_string()),
      "delta": Json(r.last.value),
      "origin": Json(r.origin.to_string()),
      "total": Json(r.total),
    }),
  )
  if !self.histograms.is_empty() || !self.exponentials.is_empty() {
    obj["version"] = Json(3)
    let histograms = self.histograms.copy()
    histograms.sort_by((a, b) => a.last_hist.series.compare(b.last_hist.series))
    obj["histograms"] = Json::array(
      histograms.map(r => {
        "last": histogram_json(r.last_hist),
        "total": histogram_json(r.total_hist),
      }),
    )
  }
  if !self.exponentials.is_empty() {
    obj["version"] = Json(4)
    let records = self.exponentials.copy()
    records.sort_by((a, b) => a.last_exp.series.compare(b.last_exp.series))
    obj["exponentials"] = Json::array(
      records.map(r => {
        "last": exp_json(r.last_exp),
        "total": exp_json(r.total_exp),
      }),
    )
  }
  base
}

///|
/// Validate a versioned checkpoint before constructing state. This checks
/// structural consistency, not authenticity of externally modified totals.
pub fn State::restore(value : Json) -> State raise StitchError {
  if value is { "version": Number(4.0, ..), .. } {
    return restore_exponentials(value)
  }
  if value is { "version": Number(3.0, ..), .. } {
    return restore_histograms(value)
  }
  if value is { "version": Number(2.0, ..), .. } {
    return restore_doubles(value)
  }
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
  let records : Array[Record] = []
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
  indexed_state(records, [], [], state.limit)
}
