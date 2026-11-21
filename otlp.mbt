///|
pub(all) struct OtlpStep {
  state : State
  request : Json
  duplicates : Int32
}

///|
fn array(value : Json, path : String) -> Array[Json] raise StitchError {
  guard value is Array(items) else { raise Invalid(path + ": expected array") }
  items
}

///|
fn text(value : Json, path : String) -> String raise StitchError {
  guard value is String(s) else { raise Invalid(path + ": expected string") }
  s
}

///|
fn attributes(
  value : Json,
  depth~ : Int32 = 0,
  budget~ : Ref[Int32] = Ref(4096),
) -> Json raise StitchError {
  let items = array(value, "attributes")
  let sorted : Array[(String, Json)] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let pair = fields(item, ["key", "value"], "attribute")
    let key = text(required(pair, "key"), "attribute.key")
    if seen.contains(key) {
      raise Invalid("duplicate attribute key " + key)
    }
    seen[key] = true
    let v = attribute_value(required(pair, "value"), depth, budget)
    sorted.push((key, { "key": Json(key), "value": v }))
  }
  sorted.sort_by((a, b) => a.0.compare(b.0))
  Json::array(sorted.map(p => p.1))
}

///|
fn metadata(value : Json, scope~ : Bool) -> Json raise StitchError {
  let allowed = if scope {
    ["name", "version", "attributes", "droppedAttributesCount"]
  } else {
    ["attributes", "droppedAttributesCount"]
  }
  let obj = fields(value, allowed, "metadata")
  let attrs = attributes(obj.get("attributes").unwrap_or(Json::array([])))
  if obj.get("droppedAttributesCount").unwrap_or(Json(0)) != Json(0) {
    raise Invalid("dropped attributes cannot be reconstructed")
  }
  if scope {
    {
      "name": Json(text(obj.get("name").unwrap_or(Json("")), "scope.name")),
      "version": Json(
        text(obj.get("version").unwrap_or(Json("")), "scope.version"),
      ),
      "attributes": attrs,
    }
  } else {
    { "attributes": attrs }
  }
}

///|
/// Convert the documented OTLP/JSON Int64/Double monotonic-Sum profile atomically.
/// Unsupported fields or kinds raise instead of being dropped. Input Json is
/// never mutated. Identity includes schema URLs and metric description.
pub fn process_otlp(
  state : State,
  request : Json,
) -> OtlpStep raise StitchError {
  let root = fields(request, ["resourceMetrics"], "request")
  let resources = array(required(root, "resourceMetrics"), "resourceMetrics")
  let output = []
  let mut current = state
  let mut duplicates = 0
  for resource in resources {
    let r = fields(
      resource,
      ["resource", "scopeMetrics", "schemaUrl"],
      "resourceMetrics[]",
    )
    let resource_id = metadata(
      r.get("resource").unwrap_or(Json::empty_object()),
      scope=false,
    )
    let rschema = text(
      r.get("schemaUrl").unwrap_or(Json("")),
      "resource schemaUrl",
    )
    let scopes = []
    for scope in array(required(r, "scopeMetrics"), "scopeMetrics") {
      let s = fields(scope, ["scope", "metrics", "schemaUrl"], "scopeMetrics[]")
      let scope_id = metadata(
        s.get("scope").unwrap_or(Json::empty_object()),
        scope=true,
      )
      let sschema = text(
        s.get("schemaUrl").unwrap_or(Json("")),
        "scope schemaUrl",
      )
      let metrics = []
      for metric in array(required(s, "metrics"), "metrics") {
        let m = fields(metric, ["name", "description", "unit", "sum"], "metric")
        let name = text(required(m, "name"), "metric.name")
        if name.is_empty() {
          raise Invalid("empty metric name")
        }
        let unit = text(m.get("unit").unwrap_or(Json("")), "metric.unit")
        let description = text(
          m.get("description").unwrap_or(Json("")),
          "metric.description",
        )
        let sum = fields(
          required(m, "sum"),
          ["dataPoints", "aggregationTemporality", "isMonotonic"],
          name + ".sum",
        )
        if required(sum, "aggregationTemporality") != Json(1) ||
          required(sum, "isMonotonic") != Json(true) {
          raise Invalid(name + ": expected DELTA monotonic Sum")
        }
        let points = []
        for point in array(required(sum, "dataPoints"), "dataPoints") {
          let p = fields(
            point,
            [
              "attributes", "startTimeUnixNano", "timeUnixNano", "asInt", "flags",
              "exemplars", "asDouble",
            ],
            name + ".dataPoint",
          )
          if p.get("flags").unwrap_or(Json(0)) != Json(0) ||
            !array(p.get("exemplars").unwrap_or(Json::array([])), "exemplars").is_empty() {
            raise Invalid(name + ": flags and exemplars unsupported")
          }
          let attrs = attributes(p.get("attributes").unwrap_or(Json::array([])))
          let identity = Json::array([
            resource_id,
            scope_id,
            Json(rschema),
            Json(sschema),
            Json(name),
            Json(unit),
            Json(description),
            attrs,
          ]).stringify()
          let start = decimal(
            required(p, "startTimeUnixNano"),
            "startTimeUnixNano",
          )
          let end = decimal(required(p, "timeUnixNano"), "timeUnixNano")
          if p.contains("asInt") == p.contains("asDouble") {
            raise Invalid("point requires exactly one numeric value")
          }
          let converted = if p.contains("asInt") {
            let sample : Sample = {
              series: identity,
              start,
              end,
              value: decimal(required(p, "asInt"), "asInt"),
            }
            let step = current.apply([sample])
            current = step.state
            duplicates += step.duplicates
            step.points.map(p => (p.start, Json(p.value.to_string())))
          } else {
            let sample : DoubleSample = {
              series: identity,
              start,
              end,
              value: finite_nonnegative(required(p, "asDouble")),
            }
            let step = current.apply_doubles([sample])
            current = step.state
            duplicates += step.duplicates
            step.points.map(p => (p.start, Json(p.value)))
          }
          for (origin, total) in converted {
            let fields = p.copy()
            fields["startTimeUnixNano"] = Json(origin.to_string())
            fields[if p.contains("asInt") { "asInt" } else { "asDouble" }] = total
            points.push(Json::object(fields))
          }
        }
        let sum_out = sum.copy()
        sum_out["dataPoints"] = Json::array(points)
        sum_out["aggregationTemporality"] = Json(2)
        let metric_out = m.copy()
        metric_out["sum"] = Json::object(sum_out)
        metrics.push(Json::object(metric_out))
      }
      let scope_out = s.copy()
      scope_out["metrics"] = Json::array(metrics)
      scopes.push(Json::object(scope_out))
    }
    let resource_out = r.copy()
    resource_out["scopeMetrics"] = Json::array(scopes)
    output.push(Json::object(resource_out))
  }
  {
    state: current,
    request: { "resourceMetrics": Json::array(output) },
    duplicates,
  }
}
