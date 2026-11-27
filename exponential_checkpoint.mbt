///|
fn bucket_json(b : ExponentialBuckets) -> Json {
  {
    "offset": Json(b.offset),
    "bucketCounts": Json::array(b.counts.map(n => Json(n.to_string()))),
  }
}

///|
fn exp_json(p : ExponentialSample) -> Json {
  let obj : Map[String, Json] = {
    "series": Json(p.series),
    "startTimeUnixNano": Json(p.start.to_string()),
    "timeUnixNano": Json(p.end.to_string()),
    "count": Json(p.count.to_string()),
    "scale": Json(p.scale),
    "zeroCount": Json(p.zero_count.to_string()),
    "zeroThreshold": Json(p.zero_threshold),
    "positive": bucket_json(p.positive),
    "negative": bucket_json(p.negative),
  }
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
fn int32_json(value : Json) -> Int32 raise StitchError {
  guard value is Number(n, ..) &&
    !n.is_nan() &&
    !n.is_inf() &&
    n >= -2147483648.0 &&
    n <= 2147483647.0 &&
    n == n.floor() else {
    raise Invalid("expected signed Int32 JSON number")
  }
  n.to_int()
}

///|
fn read_buckets(
  value : Json,
  issue~ : Ref[IssueCode] = Ref(InvalidInput),
) -> ExponentialBuckets raise StitchError {
  let obj = fields(
    value,
    ["offset", "bucketCounts"],
    "exponential buckets",
    issue~,
  )
  let counts = array(
    obj.get("bucketCounts").unwrap_or(Json::array([])),
    "bucketCounts",
  )
  if counts.length() > 1024 {
    raise Invalid("exponential side exceeds 1024 buckets")
  }
  {
    offset: int32_json(obj.get("offset").unwrap_or(Json(0))),
    counts: counts.map(n => decimal(n, "bucketCounts")),
  }
}

///|
fn read_exp(
  series : String,
  p : Map[String, Json],
  issue~ : Ref[IssueCode] = Ref(InvalidInput),
) -> ExponentialSample raise StitchError {
  let sample : ExponentialSample = {
    series,
    start: decimal(required(p, "startTimeUnixNano"), "startTimeUnixNano"),
    end: decimal(required(p, "timeUnixNano"), "timeUnixNano"),
    count: decimal(required(p, "count"), "count"),
    scale: int32_json(p.get("scale").unwrap_or(Json(0))),
    zero_count: decimal(p.get("zeroCount").unwrap_or(Json("0")), "zeroCount"),
    zero_threshold: finite_nonnegative(
      p.get("zeroThreshold").unwrap_or(Json(0)),
    ),
    positive: read_buckets(
      p.get("positive").unwrap_or(Json::empty_object()),
      issue~,
    ),
    negative: read_buckets(
      p.get("negative").unwrap_or(Json::empty_object()),
      issue~,
    ),
    sum: histogram_optional(p, "sum"),
    min: histogram_optional(p, "min"),
    max: histogram_optional(p, "max"),
  }
  validate_exp(sample)
  sample
}

///|
fn checkpoint_exp(value : Json) -> ExponentialSample raise StitchError {
  let p = fields(
    value,
    [
      "series", "startTimeUnixNano", "timeUnixNano", "count", "scale", "zeroCount",
      "zeroThreshold", "positive", "negative", "sum", "min", "max",
    ],
    "exponential checkpoint",
  )
  read_exp(text(required(p, "series"), "series"), p)
}

///|
fn bucket_count_at(b : ExponentialBuckets, index : Int64) -> Int64 {
  let i = index - b.offset.to_int64()
  if i < 0L || i >= b.counts.length().to_int64() {
    0L
  } else {
    b.counts[i.to_int()]
  }
}

///|
fn restore_exponentials(value : Json) -> State raise StitchError {
  let obj = fields(
    value,
    [
      "version", "max_series", "records", "doubles", "histograms", "exponentials",
    ],
    "checkpoint",
  )
  let base = State::restore({
    "version": 3,
    "max_series": required(obj, "max_series"),
    "records": required(obj, "records"),
    "doubles": required(obj, "doubles"),
    "histograms": required(obj, "histograms"),
  })
  let items = array(required(obj, "exponentials"), "exponentials")
  if items.length() > base.limit - base.index.length() {
    raise Invalid("checkpoint exceeds series limit")
  }
  let records : Array[ExponentialRecord] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let r = fields(item, ["last", "total"], "exponential record")
    let last = checkpoint_exp(required(r, "last"))
    let total = checkpoint_exp(required(r, "total"))
    if seen.contains(last.series) || base.index.contains(last.series) {
      raise Invalid("duplicate exponential checkpoint series")
    }
    seen[last.series] = true
    if total.series != last.series ||
      total.end != last.end ||
      total.start > last.start ||
      total.scale > last.scale ||
      total.zero_threshold != last.zero_threshold ||
      total.count < last.count ||
      total.zero_count < last.zero_count ||
      (total.sum is Some(_)) != (last.sum is Some(_)) ||
      canonical_exp(total) != total {
      raise Invalid("inconsistent exponential checkpoint")
    }
    for
      (a, b) in [
        (last.positive, total.positive),
        (last.negative, total.negative),
      ] {
      let folded = fold_buckets(a, last.scale - total.scale)
      for i, n in folded.counts {
        if bucket_count_at(b, folded.offset.to_int64() + i.to_int64()) < n {
          raise Invalid("exponential checkpoint bucket less than last delta")
        }
      }
    }
    if total.start == last.start && total != canonical_exp(last) {
      raise Invalid("initial exponential checkpoint differs from delta")
    }
    if (total.sum, last.sum) is (Some(a), Some(b)) && a < b {
      raise Invalid("exponential checkpoint sum less than delta")
    }
    if last.count > 0L && (total.min is Some(_)) != (last.min is Some(_)) {
      raise Invalid("exponential checkpoint extrema mismatch")
    }
    if (total.min, last.min) is (Some(a), Some(b)) && a > b {
      raise Invalid("exponential checkpoint minimum exceeds delta")
    }
    if (total.max, last.max) is (Some(a), Some(b)) && a < b {
      raise Invalid("exponential checkpoint maximum below delta")
    }
    records.push({ last_exp: last, total_exp: total, })
  }
  indexed_state(
    base.records,
    base.doubles,
    base.histograms,
    base.limit,
    exponentials=records,
  )
}
