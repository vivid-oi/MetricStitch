///|
/// Dense absolute-magnitude bucket indexes, shared by positive/negative sides.
#derive(Eq)
pub(all) struct ExponentialBuckets {
  offset : Int32
  counts : Array[Int64]
}

///|
pub extend ExponentialBuckets with Eq::{equal, not_equal}

///|
/// Bounded exponential Delta histogram. Scale -10..20; each side <=1024 bins.
/// Zero threshold must remain constant within a stream. Negative populations
/// require absent sum. Input and output bucket arrays are detached.
#derive(Eq)
pub(all) struct ExponentialSample {
  series : String
  start : Int64
  end : Int64
  scale : Int32
  zero_count : Int64
  zero_threshold : Double
  positive : ExponentialBuckets
  negative : ExponentialBuckets
  count : Int64
  sum : Double?
  min : Double?
  max : Double?
}

///|
pub extend ExponentialSample with Eq::{equal, not_equal}

///|
priv struct ExponentialRecord {
  last_exp : ExponentialSample
  total_exp : ExponentialSample
}

///|
pub(all) struct ExponentialStep {
  state : State
  points : Array[ExponentialSample]
  duplicates : Int32
}

///|
fn validate_exp(p : ExponentialSample) -> Unit raise StitchError {
  if p.series.is_empty() ||
    p.series.length() > 65536 ||
    p.start <= 0L ||
    p.end <= p.start ||
    p.scale < -10 ||
    p.scale > 20 {
    raise Invalid(
      "expected bounded exponential identity, increasing times and scale -10..20",
    )
  }
  ignore(finite_nonnegative(Json(p.zero_threshold)))
  let mut count = checked_count(0L, p.zero_count)
  let mut negative_count = 0L
  for side in [p.positive, p.negative] {
    if side.counts.length() > 1024 ||
      (
        !side.counts.is_empty() &&
        side.offset.to_int64() + side.counts.length().to_int64() - 1L >
        2147483647L
      ) {
      raise Invalid(
        "exponential side exceeds 1024 buckets or signed Int32 index",
      )
    }
    let mut subtotal = 0L
    for n in side.counts {
      subtotal = checked_count(subtotal, n)
    }
    count = checked_count(count, subtotal)
  }
  for n in p.negative.counts {
    negative_count = checked_count(negative_count, n)
  }
  if count != p.count {
    raise Invalid(
      "exponential population differs from zero/positive/negative counts",
    )
  }
  if p.sum is Some(sum) {
    ignore(finite_nonnegative(Json(sum)))
    if negative_count > 0L || (count == 0L && sum != 0.0) {
      raise Invalid(
        "exponential negative population requires absent sum; empty sum must be zero",
      )
    }
  }
  match (p.min, p.max) {
    (None, None) => ()
    (Some(lo), Some(hi)) => {
      ignore(finite(Json(lo)))
      ignore(finite(Json(hi)))
      if count == 0L || lo > hi {
        raise Invalid("invalid exponential extrema")
      }
    }
    _ => raise Invalid("exponential min/max must be supplied together")
  }
}

///|
fn copy_exp(p : ExponentialSample) -> ExponentialSample {
  {
    ..p,
    positive: { ..p.positive, counts: p.positive.counts.copy(), },
    negative: { ..p.negative, counts: p.negative.counts.copy(), },
  }
}

///|
// Integer arithmetic only: arithmetic right shift is floor division, including
// negative indexes. Trim empty edges; never discard a populated bucket.
fn fold_buckets(
  b : ExponentialBuckets,
  shift : Int32,
) -> ExponentialBuckets raise StitchError {
  let entries : Map[Int32, Int64] = Map([])
  for i, n in b.counts {
    if n == 0L {
      continue
    }
    let index = ((b.offset.to_int64() + i.to_int64()) >> shift).to_int()
    entries[index] = checked_count(entries.get(index).unwrap_or(0L), n)
  }
  dense_buckets(entries)
}

///|
fn dense_buckets(
  entries : Map[Int32, Int64],
) -> ExponentialBuckets raise StitchError {
  if entries.is_empty() {
    return { offset: 0, counts: [], }
  }
  let keys = entries.keys().collect()
  keys.sort()
  let lo = keys[0]
  let hi = keys[keys.length() - 1]
  let width = hi.to_int64() - lo.to_int64() + 1L
  if width > 1024L {
    raise Invalid(
      "exponential merged span exceeds 1024 buckets at minimum supported scale",
    )
  }
  {
    offset: lo,
    counts: Array::makei(width.to_int(), i => entries.get(lo + i).unwrap_or(0L)),
  }
}

///|
fn exp_span(
  a : ExponentialBuckets,
  a_shift : Int32,
  b : ExponentialBuckets,
  b_shift : Int32,
) -> Int64 {
  let indexes : Array[Int64] = []
  for (side, shift) in [(a, a_shift), (b, b_shift)] {
    for i, n in side.counts {
      if n > 0L {
        indexes.push((side.offset.to_int64() + i.to_int64()) >> shift)
      }
    }
  }
  if indexes.is_empty() {
    return 0L
  }
  let mut lo = indexes[0]
  let mut hi = lo
  for n in indexes {
    lo = lo.min(n)
    hi = hi.max(n)
  }
  hi - lo + 1L
}

///|
fn merge_exp_buckets(
  a : ExponentialBuckets,
  a_shift : Int32,
  b : ExponentialBuckets,
  b_shift : Int32,
) -> ExponentialBuckets raise StitchError {
  let entries : Map[Int32, Int64] = Map([])
  for (side, shift) in [(a, a_shift), (b, b_shift)] {
    for i, n in side.counts {
      if n == 0L {
        continue
      }
      let index = ((side.offset.to_int64() + i.to_int64()) >> shift).to_int()
      entries[index] = checked_count(entries.get(index).unwrap_or(0L), n)
    }
  }
  dense_buckets(entries)
}

///|
fn canonical_exp(p : ExponentialSample) -> ExponentialSample raise StitchError {
  {
    ..p,
    positive: fold_buckets(p.positive, 0),
    negative: fold_buckets(p.negative, 0),
  }
}

///|
fn add_exp(
  old : ExponentialSample,
  p : ExponentialSample,
  issue : Ref[IssueCode],
) -> ExponentialSample raise StitchError {
  if old.zero_threshold != p.zero_threshold ||
    (old.sum is Some(_)) != (p.sum is Some(_)) {
    issue.val = KindChanged
    raise Invalid("exponential zero threshold or sum availability changed")
  }
  let mut scale = old.scale.min(p.scale)
  while exp_span(old.positive, old.scale - scale, p.positive, p.scale - scale) >
        1024L ||
        exp_span(old.negative, old.scale - scale, p.negative, p.scale - scale) >
        1024L {
    if scale == -10 {
      raise Invalid("exponential merged span exceeds limit at scale -10")
    }
    scale -= 1
  }
  issue.val = NumericOverflow
  let count = checked_count(old.count, p.count)
  let zero_count = checked_count(old.zero_count, p.zero_count)
  let positive = merge_exp_buckets(
    old.positive,
    old.scale - scale,
    p.positive,
    p.scale - scale,
  )
  let negative = merge_exp_buckets(
    old.negative,
    old.scale - scale,
    p.negative,
    p.scale - scale,
  )
  let sum = match (old.sum, p.sum) {
    (Some(a), Some(b)) => Some(finite_nonnegative(Json(a + b)))
    _ => None
  }
  issue.val = InvalidInput
  let (min, max) = if old.count == 0L {
    (p.min, p.max)
  } else if p.count == 0L {
    (old.min, old.max)
  } else {
    match (old.min, old.max, p.min, p.max) {
      (Some(a), Some(b), Some(c), Some(d)) => (Some(a.min(c)), Some(b.max(d)))
      (None, None, None, None) => (None, None)
      _ => {
        issue.val = KindChanged
        raise Invalid("exponential extrema availability changed")
      }
    }
  }
  {
    ..p,
    start: old.start,
    scale,
    zero_count,
    positive,
    negative,
    count,
    sum,
    min,
    max,
  }
}

///|
/// Accumulate contiguous exponential histograms, aligning to the coarser scale
/// and lowering scale further when necessary to retain at most 1024 bins/side.
/// All failures preserve the original state. Exact last-delta retries emit none.
///
/// ```mbt check
/// test {
///   let p : @metricstitch.ExponentialSample = {
///     series: "zeros",
///     start: 1L,
///     end: 2L,
///     scale: 0,
///     positive: { offset: 0, counts: [], },
///     negative: { offset: 0, counts: [], },
///     zero_count: 1L,
///     zero_threshold: 0.0,
///     count: 1L,
///     sum: Some(0.0),
///     min: None,
///     max: None,
///   }
///   let state = @metricstitch.State::new().apply_exponentials([p]).state
///   assert_eq(state.apply_exponentials([p]).duplicates, 1)
/// }
/// ```
pub fn State::apply_exponentials(
  self : State,
  batch : Array[ExponentialSample],
) -> ExponentialStep raise StitchError {
  self.apply_exp_impl(batch, Ref(InvalidInput))
}

///|
fn State::apply_exp_impl(
  self : State,
  batch : Array[ExponentialSample],
  issue : Ref[IssueCode],
  writable~ : Bool = false,
) -> ExponentialStep raise StitchError {
  let records = if writable {
    self.exponentials
  } else {
    self.exponentials.copy()
  }
  let index = if writable { self.index } else { self.index.copy() }
  let points : Array[ExponentialSample] = []
  let mut duplicates = 0
  for sample in batch {
    validate_exp(sample)
    let p = copy_exp(sample)
    let slot = match index.get(p.series) {
      None => -1
      Some(ExponentialSlot(i)) => i
      _ => {
        issue.val = KindChanged
        raise Invalid("series changed metric kind")
      }
    }
    let total = if slot < 0 {
      if index.length() == self.limit {
        issue.val = SeriesLimit
        raise Invalid("series limit exceeded")
      }
      canonical_exp(p)
    } else {
      let old = records[slot]
      if old.last_exp == p {
        duplicates += 1
        continue
      }
      if p.start != old.last_exp.end {
        issue.val = interval_issue(
          p.start,
          p.end,
          old.last_exp.start,
          old.last_exp.end,
        )
        raise Invalid("noncontiguous exponential interval")
      }
      add_exp(old.total_exp, p, issue)
    }
    let record : ExponentialRecord = { last_exp: p, total_exp: total, }
    if slot < 0 {
      index[p.series] = ExponentialSlot(records.length())
      records.push(record)
    } else {
      records[slot] = record
    }
    points.push(copy_exp(total))
  }
  { state: { ..self, exponentials: records, index, }, points, duplicates, }
}
