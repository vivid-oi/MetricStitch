///|
fn histogram_json(p : HistogramSample) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["series"] = Json(p.series)
  obj["startTimeUnixNano"] = Json(p.start.to_string())
  obj["timeUnixNano"] = Json(p.end.to_string())
  obj["explicitBounds"] = Json::array(p.bounds.map(n => Json(n)))
  obj["bucketCounts"] = Json::array(p.counts.map(n => Json(n.to_string())))
  obj["count"] = Json(p.count.to_string())
  if p.sum is Some(n) {
    obj["sum"] = Json(n)
  }
  if p.min is Some(n) {
    obj["min"] = Json(n)
  }
  if p.max is Some(n) {
    obj["max"] = Json(n)
  }
  Json::object(obj)
}

///|
fn histogram_optional(
  obj : Map[String, Json],
  key : String,
) -> Double? raise StitchError {
  match obj.get(key) {
    Some(value) => Some(finite(value))
    None => None
  }
}

///|
fn read_histogram(
  series : String,
  p : Map[String, Json],
) -> HistogramSample raise StitchError {
  let sample : HistogramSample = {
    series,
    start: decimal(required(p, "startTimeUnixNano"), "startTimeUnixNano"),
    end: decimal(required(p, "timeUnixNano"), "timeUnixNano"),
    bounds: array(required(p, "explicitBounds"), "explicitBounds").map(finite),
    counts: array(required(p, "bucketCounts"), "bucketCounts").map(n => {
      decimal(n, "bucketCounts")
    }),
    count: decimal(required(p, "count"), "count"),
    sum: histogram_optional(p, "sum"),
    min: histogram_optional(p, "min"),
    max: histogram_optional(p, "max"),
  }
  validate_histogram(sample)
  sample
}

///|
fn checkpoint_histogram(value : Json) -> HistogramSample raise StitchError {
  let p = fields(
    value,
    [
      "series", "startTimeUnixNano", "timeUnixNano", "explicitBounds", "bucketCounts",
      "count", "sum", "min", "max",
    ],
    "histogram checkpoint",
  )
  read_histogram(text(required(p, "series"), "series"), p)
}

///|
fn restore_histograms(value : Json) -> State raise StitchError {
  let obj = fields(
    value,
    ["version", "max_series", "records", "doubles", "histograms"],
    "checkpoint",
  )
  let base = State::restore({
    "version": 2,
    "max_series": required(obj, "max_series"),
    "records": required(obj, "records"),
    "doubles": required(obj, "doubles"),
  })
  let items = array(required(obj, "histograms"), "histograms")
  if items.length() > base.limit - base.records.length() - base.doubles.length() {
    raise Invalid("checkpoint exceeds series limit")
  }
  let records : Array[HistogramRecord] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let r = fields(item, ["last", "total"], "histogram record")
    let last = checkpoint_histogram(required(r, "last"))
    let total = checkpoint_histogram(required(r, "total"))
    ignore(base.apply_histograms([last]))
    if seen.contains(last.series) {
      raise Invalid("duplicate histogram checkpoint series")
    }
    seen[last.series] = true
    if total.series != last.series ||
      total.end != last.end ||
      total.start > last.start ||
      total.bounds != last.bounds ||
      total.count < last.count {
      raise Invalid("inconsistent histogram checkpoint")
    }
    for i, n in total.counts {
      if n < last.counts[i] {
        raise Invalid("checkpoint bucket less than last delta")
      }
    }
    if total.start == last.start && total != last {
      raise Invalid("initial histogram checkpoint differs from delta")
    }
    if (total.sum is Some(_)) != (last.sum is Some(_)) {
      raise Invalid("checkpoint sum availability mismatch")
    }
    if last.count > 0L &&
      (
        (total.min is Some(_)) != (last.min is Some(_)) ||
        (total.max is Some(_)) != (last.max is Some(_))
      ) {
      raise Invalid("checkpoint extrema availability mismatch")
    }
    if (total.min, last.min) is (Some(a), Some(b)) && a > b {
      raise Invalid("checkpoint minimum exceeds last minimum")
    }
    if (total.max, last.max) is (Some(a), Some(b)) && a < b {
      raise Invalid("checkpoint maximum below last maximum")
    }
    records.push({ last_hist: last, total_hist: total, })
  }
  {
    records: base.records,
    doubles: base.doubles,
    histograms: records,
    limit: base.limit,
  }
}
