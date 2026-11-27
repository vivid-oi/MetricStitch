///|
/// Explicit buckets have upper-inclusive bounds. Counts and population fit Int64.
/// sum is optional. min/max must be both present or both absent.
#derive(Eq)
pub(all) struct HistogramSample {
  series : String
  start : Int64
  end : Int64
  bounds : Array[Double]
  counts : Array[Int64]
  count : Int64
  sum : Double?
  min : Double?
  max : Double?
}

///|
pub extend HistogramSample with Eq::{equal, not_equal}

///|
priv struct HistogramRecord {
  last_hist : HistogramSample
  total_hist : HistogramSample
}

///|
pub(all) struct HistogramStep {
  state : State
  points : Array[HistogramSample]
  duplicates : Int32
}

///|
fn checked_count(a : Int64, b : Int64) -> Int64 raise StitchError {
  if a < 0L || b < 0L || b > 9223372036854775807L - a {
    raise Invalid("histogram count overflow or negative count")
  }
  a + b
}

///|
fn finite(value : Json) -> Double raise StitchError {
  guard value is Number(n, ..) && !n.is_inf() && !n.is_nan() else {
    raise Invalid("expected finite histogram number")
  }
  n
}

///|
fn validate_histogram(p : HistogramSample) -> Unit raise StitchError {
  if p.series.is_empty() ||
    p.series.length() > 65536 ||
    p.start <= 0L ||
    p.end <= p.start {
    raise Invalid("invalid histogram identity or interval")
  }
  if p.bounds.length() > 1024 || p.counts.length() != p.bounds.length() + 1 {
    raise Invalid("histogram requires bounds+1 buckets and at most 1024 bounds")
  }
  for i, bound in p.bounds {
    ignore(finite(Json(bound)))
    if i > 0 && bound <= p.bounds[i - 1] {
      raise Invalid("histogram bounds must strictly increase")
    }
  }
  let mut count = 0L
  for bucket in p.counts {
    count = checked_count(count, bucket)
  }
  if count != p.count {
    raise Invalid("histogram population differs from bucket total")
  }
  if p.sum is Some(sum) {
    ignore(finite(Json(sum)))
    if count == 0L && sum != 0.0 {
      raise Invalid("empty histogram has nonzero sum")
    }
  }
  match (p.min, p.max) {
    (None, None) => ()
    (Some(lo), Some(hi)) => {
      ignore(finite(Json(lo)))
      ignore(finite(Json(hi)))
      if count == 0L || lo > hi {
        raise Invalid("invalid histogram extrema")
      }
    }
    _ => raise Invalid("histogram min and max must be supplied together")
  }
}

///|
fn copy_histogram(p : HistogramSample) -> HistogramSample {
  { ..p, bounds: p.bounds.copy(), counts: p.counts.copy(), }
}

///|
fn add_histogram(
  old : HistogramSample,
  p : HistogramSample,
) -> HistogramSample raise StitchError {
  if old.bounds != p.bounds {
    raise Invalid("histogram bucket layout changed")
  }
  let count = checked_count(old.count, p.count)
  let counts = old.counts.mapi((i, n) => checked_count(n, p.counts[i]))
  let sum = match (old.sum, p.sum) {
    (Some(a), Some(b)) => Some(finite(Json(a + b)))
    (None, None) => None
    _ => raise Invalid("histogram sum availability changed")
  }
  let (min, max) = if old.count == 0L {
    (p.min, p.max)
  } else if p.count == 0L {
    (old.min, old.max)
  } else {
    match (old.min, old.max, p.min, p.max) {
      (Some(a), Some(b), Some(c), Some(d)) => (Some(a.min(c)), Some(b.max(d)))
      (None, None, None, None) => (None, None)
      _ => raise Invalid("histogram extrema availability changed")
    }
  }
  {
    ..p,
    start: old.start,
    bounds: p.bounds.copy(),
    counts,
    count,
    sum,
    min,
    max,
  }
}

///|
/// Accumulate matching explicit-bucket histograms. Arrays are detached on entry
/// and on return. A rejected batch leaves the old state reusable.
///
/// ```mbt check
/// test {
///   let p : @metricstitch.HistogramSample = {
///     series: "latency",
///     start: 1L,
///     end: 2L,
///     bounds: [1.0],
///     counts: [1L, 1L],
///     count: 2L,
///     sum: Some(2.0),
///     min: Some(0.0),
///     max: Some(2.0),
///   }
///   let first = @metricstitch.State::new().apply_histograms([p])
///   assert_eq(first.state.apply_histograms([p]).duplicates, 1)
/// }
/// ```
pub fn State::apply_histograms(
  self : State,
  batch : Array[HistogramSample],
) -> HistogramStep raise StitchError {
  self.apply_histogram_impl(batch, Ref(InvalidInput))
}

///|
fn State::apply_histogram_impl(
  self : State,
  batch : Array[HistogramSample],
  issue : Ref[IssueCode],
) -> HistogramStep raise StitchError {
  let records = self.histograms.copy()
  let points = []
  let mut duplicates = 0
  for supplied in batch {
    validate_histogram(supplied)
    let p = copy_histogram(supplied)
    if self.records.any(r => r.last.series == p.series) ||
      self.doubles.any(r => r.last.series == p.series) {
      issue.val = KindChanged
      raise Invalid("series changed metric kind")
    }
    let mut index = -1
    for i, record in records {
      if record.last_hist.series == p.series {
        index = i
        break
      }
    }
    let total = if index < 0 {
      if records.length() + self.records.length() + self.doubles.length() ==
        self.limit {
        issue.val = SeriesLimit
        raise Invalid("series limit exceeded")
      }
      copy_histogram(p)
    } else {
      let old = records[index]
      if old.last_hist == p {
        duplicates += 1
        continue
      }
      if p.start != old.last_hist.end {
        issue.val = interval_issue(
          p.start,
          p.end,
          old.last_hist.start,
          old.last_hist.end,
        )
        raise Invalid("noncontiguous histogram interval")
      }
      if old.total_hist.bounds != p.bounds ||
        (old.total_hist.sum is Some(_)) != (p.sum is Some(_)) ||
        (
          old.total_hist.count > 0L &&
          p.count > 0L &&
          (old.total_hist.min is Some(_)) != (p.min is Some(_))
        ) {
        issue.val = KindChanged
      } else {
        issue.val = NumericOverflow
      }
      let total = add_histogram(old.total_hist, p)
      issue.val = InvalidInput
      total
    }
    let record : HistogramRecord = { last_hist: p, total_hist: total, }
    if index < 0 {
      records.push(record)
    } else {
      records[index] = record
    }
    points.push(copy_histogram(total))
  }
  {
    state: {
      records: self.records,
      doubles: self.doubles,
      histograms: records,
      limit: self.limit,
    },
    points,
    duplicates,
  }
}
