///|
priv struct QueuedOtlp {
  point : BufferedPoint
  request : Json
}

///|
priv struct OtlpCapture {
  entries : Array[QueuedOtlp]
  mut used : Int32
}

///|
fn single_otlp_point(
  r : Map[String, Json],
  s : Map[String, Json],
  m : Map[String, Json],
  kind : String,
  p : Json,
) -> Json {
  let data = match m.get(kind) {
    Some(Object(data)) => data.copy()
    _ => abort("validated metric data")
  }
  data["dataPoints"] = Json::array([p])
  let metric = m.copy()
  metric[kind] = Json::object(data)
  let scope = s.copy()
  scope["metrics"] = Json::array([Json::object(metric)])
  let resource = r.copy()
  resource["scopeMetrics"] = Json::array([Json::object(scope)])
  { "resourceMetrics": [Json::object(resource)] }
}

///|
fn OtlpCapture::add(
  self : OtlpCapture,
  point : BufferedPoint,
  request : Json,
) -> Unit raise StitchError {
  if self.entries.length() == 4096 {
    raise Invalid("OTLP reorder request exceeds 4096 stateful points")
  }
  let encoded = request.stringify()
  if encoded.length() > 4000000 - self.used {
    raise Invalid("OTLP reorder metadata exceeds 4M code units")
  }
  self.used += encoded.length()
  self.entries.push({ point, request: parse_input(encoded), })
}

///|
fn capture_otlp(request : Json) -> (Array[QueuedOtlp], Json) raise StitchError {
  let capture : OtlpCapture = { entries: [], used: 0, }
  let location = Ref("")
  let step = process_otlp_impl(
    State::new(),
    request,
    location,
    collecting=Some(capture),
  ) catch {
    Invalid(message) => raise Invalid(location.val + ": " + message)
  }
  (capture.entries, step.request)
}

///|
fn render_otlp_point(
  entry : QueuedOtlp,
  output : BufferedPoint,
) -> Json raise StitchError {
  guard entry.request is { "resourceMetrics": [Object(r)], .. } &&
    r.get("scopeMetrics") is Some(Array([Object(s)])) &&
    s.get("metrics") is Some(Array([Object(m)])) else {
    abort("captured envelope shape")
  }
  let (kind, encoded) : (String, Json) = match output {
    Counter(p) =>
      (
        "sum",
        {
          "startTimeUnixNano": Json(p.start.to_string()),
          "timeUnixNano": Json(p.end.to_string()),
          "asInt": Json(p.value.to_string()),
        },
      )
    DoubleCounter(p) =>
      (
        "sum",
        {
          "startTimeUnixNano": Json(p.start.to_string()),
          "timeUnixNano": Json(p.end.to_string()),
          "asDouble": Json(p.value),
        },
      )
    Histogram(p) => ("histogram", histogram_json(p))
    Exponential(p) => ("exponentialHistogram", exp_json(p))
  }
  guard m.get(kind) is Some(Object(data)) &&
    data.get("dataPoints") is Some(Array([Object(point)])) &&
    encoded is Object(values) else {
    abort("captured point shape")
  }
  let point_out = point.copy()
  for key, value in values {
    if key != "series" {
      point_out[key] = value
    }
  }
  let result = single_otlp_point(r, s, m, kind, Json::object(point_out))
  guard result
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": [Object(metric)], .. }], .. },
      ],
      ..
    } &&
    metric.get(kind) is Some(Object(body)) else {
    abort("render shape")
  }
  body["aggregationTemporality"] = Json(2)
  // Output must not share mutable JSON with old or pending buffers.
  parse_input(result.stringify())
}
