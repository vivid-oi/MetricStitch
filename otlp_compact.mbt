///|
// Helpers only receive objects from the strict, bounded cumulative validator.
// Equality is deliberately conservative: compare rendered headers, not the
// normalized stream identity, so omitted fields and attribute order survive.
fn compact_parts(value : Json, child : String) -> (String, Array[Json]) {
  guard value is Object(fields) && fields.get(child) is Some(Array(items)) else {
    abort("validated compaction container")
  }
  let header = fields.copy()
  ignore(header.remove(child))
  (Json::object(header).stringify(), items)
}

///|
fn compact_metric_parts(metric : Json) -> (String, Array[Json]) {
  guard metric is Object(fields) else { abort("validated metric") }
  for kind in ["sum", "histogram", "gauge", "exponentialHistogram"] {
    if fields.get(kind) is Some(Object(body)) &&
      body.get("dataPoints") is Some(Array(points)) {
      let data = body.copy()
      ignore(data.remove("dataPoints"))
      let header = fields.copy()
      header[kind] = Json::object(data)
      return (Json::object(header).stringify(), points)
    }
  }
  abort("validated metric kind")
}

///|
fn append_compact_metric(output : Array[Json], metric : Json) -> Unit {
  let (header, points) = compact_metric_parts(metric)
  if !points.is_empty() && output.last() is Some(previous) {
    let (old_header, old_points) = compact_metric_parts(previous)
    if !old_points.is_empty() && header == old_header {
      for point in points {
        old_points.push(point)
      }
      return
    }
  }
  output.push(metric)
}

///|
fn append_compact_scope(output : Array[Json], scope : Json) -> Unit {
  let (header, metrics) = compact_parts(scope, "metrics")
  if !metrics.is_empty() && output.last() is Some(previous) {
    let (old_header, old_metrics) = compact_parts(previous, "metrics")
    if !old_metrics.is_empty() && header == old_header {
      for metric in metrics {
        append_compact_metric(old_metrics, metric)
      }
      return
    }
  }
  output.push(scope)
}

///|
fn append_compact_resource(output : Array[Json], resource : Json) -> Unit {
  let (header, scopes) = compact_parts(resource, "scopeMetrics")
  if !scopes.is_empty() && output.last() is Some(previous) {
    let (old_header, old_scopes) = compact_parts(previous, "scopeMetrics")
    if !old_scopes.is_empty() && header == old_header {
      for scope in scopes {
        append_compact_scope(old_scopes, scope)
      }
      return
    }
  }
  output.push(resource)
}

///|
/// Coalesce adjacent equal headers in supported cumulative OTLP/JSON. Every
/// point and its traversal order, exact values and metadata are preserved.
/// Empty containers are barriers at their own level; no sorting, aggregation,
/// schema guessing or removal of unsupported fields occurs. Input is detached.
///
/// ```mbt check
/// test {
///   let empty : Json = { "resourceMetrics": [] }
///   assert_eq(@metricstitch.compact_otlp(empty), empty)
/// }
/// ```
pub fn compact_otlp(request : Json) -> Json raise StitchError {
  let owned = parse_input(request.stringify())
  let location = Ref("")
  ignore(process_otlp_impl(State::new(), owned, location, cumulative=true)) catch {
    Invalid(message) => raise Invalid(location.val + ": " + message)
  }
  guard owned is { "resourceMetrics": Array(resources), .. } else {
    abort("validated resources")
  }
  let output : Array[Json] = []
  for resource in resources {
    guard resource is Object(r) && r.get("scopeMetrics") is Some(Array(scopes)) else {
      abort("validated scopes")
    }
    let scope_output : Array[Json] = []
    for scope in scopes {
      guard scope is Object(s) && s.get("metrics") is Some(Array(metrics)) else {
        abort("validated metrics")
      }
      let metric_output : Array[Json] = []
      for metric in metrics {
        append_compact_metric(metric_output, metric)
      }
      s["metrics"] = Json::array(metric_output)
      append_compact_scope(scope_output, scope)
    }
    r["scopeMetrics"] = Json::array(scope_output)
    append_compact_resource(output, resource)
  }
  // Re-apply parser budgets even though compaction only removes repeated data.
  parse_input(({ "resourceMetrics": Json::array(output) } : Json).stringify())
}
