///|
fn validate_coarse_bounds(bounds : Array[Double]) -> Unit raise StitchError {
  if bounds.length() > 1024 {
    raise Invalid("coarse layout exceeds 1024 bounds")
  }
  for i, bound in bounds {
    ignore(finite(Json(bound)))
    if i > 0 && bound <= bounds[i - 1] {
      raise Invalid("coarse bounds must strictly increase")
    }
  }
}

///|
/// Combine explicit buckets exactly. Every target bound must occur in the
/// source layout; splitting/interpolation is refused. Empty bounds produce one
/// bucket. Population, sum, extrema, identity and interval are retained.
///
/// ```mbt check
/// test {
///   let p : @metricstitch.HistogramSample = {
///     series: "latency",
///     start: 1L,
///     end: 2L,
///     bounds: [1.0, 2.0],
///     counts: [1L, 2L, 3L],
///     count: 6L,
///     sum: None,
///     min: None,
///     max: None,
///   }
///   assert_eq(p.coarsen([2.0]).counts, [3L, 3L])
/// }
/// ```
pub fn HistogramSample::coarsen(
  self : HistogramSample,
  bounds : Array[Double],
) -> HistogramSample raise StitchError {
  validate_histogram(self)
  validate_coarse_bounds(bounds)
  let counts : Array[Int64] = []
  let mut cursor = 0
  for bound in bounds {
    let mut count = 0L
    while cursor < self.bounds.length() && self.bounds[cursor] < bound {
      count = checked_count(count, self.counts[cursor])
      cursor += 1
    }
    if cursor == self.bounds.length() || self.bounds[cursor] != bound {
      raise Invalid("coarse layout contains a bound absent from the source")
    }
    count = checked_count(count, self.counts[cursor])
    cursor += 1
    counts.push(count)
  }
  let mut rest = 0L
  for i in cursor..<self.counts.length() {
    rest = checked_count(rest, self.counts[i])
  }
  counts.push(rest)
  { ..self, bounds: bounds.copy(), counts, }
}

///|
/// Explicitly migrate one tracked histogram and its retry delta. Replay the
/// coarsened last delta for retry detection after this migration. Other streams
/// and the original State retain their previous layout and behavior.
pub fn State::coarsen_histogram(
  self : State,
  series : String,
  bounds : Array[Double],
) -> State raise StitchError {
  guard self.index.get(series) is Some(HistogramSlot(index)) else {
    raise Invalid("coarsening requires a tracked explicit histogram identity")
  }
  let record = self.histograms[index]
  let last = record.last_hist.coarsen(bounds)
  let total = record.total_hist.coarsen(bounds)
  let records = self.histograms.copy()
  records[index] = { last_hist: last, total_hist: total, }
  { ..self, histograms: records, }
}

///|
/// Coarsen supported Delta OTLP explicit Histograms without accumulating them.
/// Other supported kinds and all metadata remain unchanged. Shape/profile
/// validation is shared with the reorder adapter; no interval order is assumed.
pub fn coarsen_otlp_histograms(
  request : Json,
  bounds : Array[Double],
) -> Json raise StitchError {
  validate_coarse_bounds(bounds)
  let owned = parse_input(request.stringify())
  ignore(capture_otlp(owned))
  guard owned is { "resourceMetrics": Array(resources), .. } else {
    abort("validated request")
  }
  for resource in resources {
    guard resource is { "scopeMetrics": Array(scopes), .. } else {
      abort("validated scopes")
    }
    for scope in scopes {
      guard scope is { "metrics": Array(metrics), .. } else {
        abort("validated metrics")
      }
      for metric in metrics {
        if metric is { "histogram": { "dataPoints": Array(points), .. }, .. } {
          for point in points {
            guard point is Object(fields) else {
              abort("validated histogram point")
            }
            let coarse = read_histogram("coarsen", fields).coarsen(bounds)
            fields["explicitBounds"] = Json::array(
              coarse.bounds.map(n => Json(n)),
            )
            fields["bucketCounts"] = Json::array(
              coarse.counts.map(n => Json(n.to_string())),
            )
          }
        }
      }
    }
  }
  parse_input(owned.stringify())
}
