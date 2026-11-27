///|
// Gauge data is validated and carried through, with no cumulative state.
fn validate_gauge(
  value : Json,
  location : Ref[String],
  path : String,
  issue~ : Ref[IssueCode],
) -> Unit raise StitchError {
  location.val = path
  let gauge = fields(value, ["dataPoints"], "gauge", issue~)
  location.val = path + "/dataPoints"
  for i, point in array(required(gauge, "dataPoints"), "gauge.dataPoints") {
    location.val = path + "/dataPoints/" + i.to_string()
    let p = fields(
      point,
      [
        "attributes", "startTimeUnixNano", "timeUnixNano", "asInt", "asDouble", "flags",
        "exemplars",
      ],
      "gauge point",
      issue~,
    )
    ignore(attributes(p.get("attributes").unwrap_or(Json::array([])), issue~))
    let end = decimal(required(p, "timeUnixNano"), "timeUnixNano")
    let start = decimal(
      p.get("startTimeUnixNano").unwrap_or(Json("0")),
      "startTimeUnixNano",
    )
    if end <= 0L || start > end {
      raise Invalid(
        "gauge requires a positive timestamp and optional start <= end",
      )
    }
    if p.contains("asInt") == p.contains("asDouble") {
      raise Invalid("gauge requires exactly one numeric value")
    }
    if p.contains("asInt") {
      ignore(signed_decimal(required(p, "asInt"), "asInt"))
    } else {
      ignore(finite(required(p, "asDouble")))
    }
    if p.get("flags").unwrap_or(Json(0)) != Json(0) ||
      !array(p.get("exemplars").unwrap_or(Json::array([])), "exemplars").is_empty() {
      issue.val = UnsupportedData
      raise Invalid("gauge flags and exemplars unsupported")
    }
  }
}
