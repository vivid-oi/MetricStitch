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
  issue~ : Ref[IssueCode] = Ref(InvalidInput),
) -> Json raise StitchError {
  let items = array(value, "attributes")
  let sorted : Array[(String, Json)] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let pair = fields(item, ["key", "value"], "attribute", issue~)
    let key = text(required(pair, "key"), "attribute.key")
    if seen.contains(key) {
      raise Invalid("duplicate attribute key " + key)
    }
    seen[key] = true
    let v = attribute_value(required(pair, "value"), depth, budget, issue)
    sorted.push((key, { "key": Json(key), "value": v }))
  }
  sorted.sort_by((a, b) => a.0.compare(b.0))
  Json::array(sorted.map(p => p.1))
}

///|
fn metadata(
  value : Json,
  scope~ : Bool,
  issue~ : Ref[IssueCode],
) -> Json raise StitchError {
  let allowed = if scope {
    ["name", "version", "attributes", "droppedAttributesCount"]
  } else {
    ["attributes", "droppedAttributesCount"]
  }
  let obj = fields(value, allowed, "metadata", issue~)
  let attrs = attributes(
    obj.get("attributes").unwrap_or(Json::array([])),
    issue~,
  )
  if obj.get("droppedAttributesCount").unwrap_or(Json(0)) != Json(0) {
    issue.val = UnsupportedData
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
fn process_otlp_impl(
  state : State,
  request : Json,
  location : Ref[String],
  cumulative~ : Bool = false,
  issue~ : Ref[IssueCode] = Ref(InvalidInput),
) -> OtlpStep raise StitchError {
  let root = fields(request, ["resourceMetrics"], "request", issue~)
  location.val = "/resourceMetrics"
  let resources = array(required(root, "resourceMetrics"), "resourceMetrics")
  let output = []
  let mut current = state.detached()
  let mut duplicates = 0
  for ri, resource in resources {
    let resource_path = "/resourceMetrics/" + ri.to_string()
    location.val = resource_path
    let r = fields(
      resource,
      ["resource", "scopeMetrics", "schemaUrl"],
      "resourceMetrics[]",
      issue~,
    )
    location.val = resource_path + "/resource"
    let resource_id = metadata(
      r.get("resource").unwrap_or(Json::empty_object()),
      scope=false,
      issue~,
    )
    location.val = resource_path + "/schemaUrl"
    let rschema = text(
      r.get("schemaUrl").unwrap_or(Json("")),
      "resource schemaUrl",
    )
    let scopes = []
    location.val = resource_path + "/scopeMetrics"
    for si, scope in array(required(r, "scopeMetrics"), "scopeMetrics") {
      let scope_path = resource_path + "/scopeMetrics/" + si.to_string()
      location.val = scope_path
      let s = fields(
        scope,
        ["scope", "metrics", "schemaUrl"],
        "scopeMetrics[]",
        issue~,
      )
      location.val = scope_path + "/scope"
      let scope_id = metadata(
        s.get("scope").unwrap_or(Json::empty_object()),
        scope=true,
        issue~,
      )
      location.val = scope_path + "/schemaUrl"
      let sschema = text(
        s.get("schemaUrl").unwrap_or(Json("")),
        "scope schemaUrl",
      )
      let metrics = []
      location.val = scope_path + "/metrics"
      for mi, metric in array(required(s, "metrics"), "metrics") {
        let metric_path = scope_path + "/metrics/" + mi.to_string()
        location.val = metric_path
        let m = fields(
          metric,
          ["name", "description", "unit", "sum", "histogram", "gauge"],
          "metric",
          issue~,
        )
        let kinds = ["sum", "histogram", "gauge"].filter(k => m.contains(k))
        guard kinds is [kind] else {
          raise Invalid("metric requires exactly one supported kind")
        }
        let is_histogram = kind == "histogram"
        let name = text(required(m, "name"), "metric.name")
        if name.is_empty() {
          raise Invalid("empty metric name")
        }
        let unit = text(m.get("unit").unwrap_or(Json("")), "metric.unit")
        let description = text(
          m.get("description").unwrap_or(Json("")),
          "metric.description",
        )
        if kind == "gauge" {
          validate_gauge(
            required(m, "gauge"),
            location,
            metric_path + "/gauge",
            issue~,
          )
          metrics.push(metric)
          continue
        }
        location.val = metric_path + "/" + kind
        let sum = fields(
          required(m, kind),
          if is_histogram {
            ["dataPoints", "aggregationTemporality"]
          } else {
            ["dataPoints", "aggregationTemporality", "isMonotonic"]
          },
          name + "." + kind,
          issue~,
        )
        if required(sum, "aggregationTemporality") !=
          Json(if cumulative { 2 } else { 1 }) ||
          (!is_histogram && required(sum, "isMonotonic") != Json(true)) {
          issue.val = UnsupportedData
          raise Invalid(name + ": unexpected temporality or non-monotonic Sum")
        }
        let points = []
        let points_path = metric_path + "/" + kind + "/dataPoints"
        location.val = points_path
        for pi, point in array(required(sum, "dataPoints"), "dataPoints") {
          location.val = points_path + "/" + pi.to_string()
          let p = fields(
            point,
            if is_histogram {
              [
                "attributes", "startTimeUnixNano", "timeUnixNano", "count", "sum",
                "min", "max", "explicitBounds", "bucketCounts", "flags", "exemplars",
              ]
            } else {
              [
                "attributes", "startTimeUnixNano", "timeUnixNano", "asInt", "flags",
                "exemplars", "asDouble",
              ]
            },
            name + ".dataPoint",
            issue~,
          )
          if p.get("flags").unwrap_or(Json(0)) != Json(0) ||
            !array(p.get("exemplars").unwrap_or(Json::array([])), "exemplars").is_empty() {
            issue.val = UnsupportedData
            raise Invalid(name + ": flags and exemplars unsupported")
          }
          let attrs = attributes(
            p.get("attributes").unwrap_or(Json::array([])),
            issue~,
          )
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
          if !is_histogram && p.contains("asInt") == p.contains("asDouble") {
            raise Invalid("point requires exactly one numeric value")
          }
          let converted = if is_histogram {
            let point_state = if cumulative { State::new() } else { current }
            let step = point_state.apply_histogram_impl(
              [read_histogram(identity, p)],
              issue,
              writable=true,
            )
            current = step.state
            duplicates += step.duplicates
            step.points.map(p => (p.start, histogram_json(p)))
          } else if p.contains("asInt") {
            let sample : Sample = {
              series: identity,
              start,
              end,
              value: decimal(required(p, "asInt"), "asInt"),
            }
            let point_state = if cumulative { State::new() } else { current }
            let step = point_state.apply_int_impl(
              [sample],
              issue,
              writable=true,
            )
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
            let point_state = if cumulative { State::new() } else { current }
            let step = point_state.apply_double_impl(
              [sample],
              issue,
              writable=true,
            )
            current = step.state
            duplicates += step.duplicates
            step.points.map(p => (p.start, Json(p.value)))
          }
          for (origin, total) in converted {
            let fields = p.copy()
            fields["startTimeUnixNano"] = Json(origin.to_string())
            if is_histogram {
              guard total is Object(encoded) else {
                abort("histogram serialization")
              }
              for key, value in encoded {
                if key != "series" {
                  fields[key] = value
                }
              }
            } else {
              fields[if p.contains("asInt") { "asInt" } else { "asDouble" }] = total
            }
            points.push(Json::object(fields))
          }
        }
        let sum_out = sum.copy()
        sum_out["dataPoints"] = Json::array(points)
        sum_out["aggregationTemporality"] = Json(2)
        let metric_out = m.copy()
        metric_out[kind] = Json::object(sum_out)
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
