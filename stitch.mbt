///|
pub suberror StitchError {
  Invalid(String)
}

///|
/// A nonnegative Int64 delta over (start, end], with positive nanosecond times.
/// Direct callers own the stable series identity. The OTLP adapter supplies it.
#derive(Eq)
pub(all) struct Sample {
  series : String
  start : Int64
  end : Int64
  value : Int64
}

///|
pub extend Sample with Eq::{equal, not_equal}

///|
priv struct Record {
  last : Sample
  origin : Int64
  total : Int64
}

///|
pub struct State {
  priv records : Array[Record]
  priv doubles : Array[DoubleRecord]
  priv histograms : Array[HistogramRecord]
  priv limit : Int32
  priv index : Map[String, SeriesSlot]
}

///|
pub(all) struct Step {
  state : State
  points : Array[Sample]
  duplicates : Int32
}

///|
/// Create a bounded state. Applying batches returns a new state.
pub fn State::new(max_series~ : Int32 = 1024) -> State raise StitchError {
  if max_series <= 0 || max_series > 100000 {
    raise Invalid("max_series must be in 1..100000")
  }
  {
    records: [],
    doubles: [],
    histograms: [],
    limit: max_series,
    index: Map([]),
  }
}

///|
/// Accumulate consecutive intervals atomically. Exact last-point retries emit
/// nothing. Gaps, overlap, older retries and conflicting retries are rejected.
///
/// ```mbt check
/// test {
///   let s = @metricstitch.State::new()
///   let p : @metricstitch.Sample = {
///     series: "requests",
///     start: 1L,
///     end: 2L,
///     value: 7L,
///   }
///   let first = s.apply([p])
///   assert_eq(first.state.apply([p]).duplicates, 1)
/// }
/// ```
pub fn State::apply(
  self : State,
  batch : Array[Sample],
) -> Step raise StitchError {
  self.apply_int_impl(batch, Ref(InvalidInput))
}

///|
fn State::apply_int_impl(
  self : State,
  batch : Array[Sample],
  issue : Ref[IssueCode],
  writable~ : Bool = false,
) -> Step raise StitchError {
  let records = if writable { self.records } else { self.records.copy() }
  let lookup = if writable { self.index } else { self.index.copy() }
  let points = []
  let mut duplicates = 0
  for sample in batch {
    let slot = lookup.get(sample.series)
    if slot is Some(DoubleSlot(_) | HistogramSlot(_)) {
      issue.val = KindChanged
      raise Invalid("series changed numeric kind")
    }
    if sample.series.is_empty() ||
      sample.series.length() > 65536 ||
      sample.start <= 0L ||
      sample.end <= sample.start ||
      sample.value < 0L {
      raise Invalid(
        "expected a bounded series key, positive increasing times and nonnegative Int64 delta",
      )
    }
    let index = match slot {
      Some(IntSlot(i)) => i
      _ => -1
    }
    let next : Record = if index < 0 {
      if records.length() + self.doubles.length() + self.histograms.length() ==
        self.limit {
        issue.val = SeriesLimit
        raise Invalid("series limit exceeded")
      }
      { last: sample, origin: sample.start, total: sample.value, }
    } else {
      let old = records[index]
      if sample == old.last {
        duplicates += 1
        continue
      }
      if sample.start != old.last.end {
        issue.val = interval_issue(
          sample.start,
          sample.end,
          old.last.start,
          old.last.end,
        )
        raise Invalid("noncontiguous interval for " + sample.series)
      }
      if sample.value > 9223372036854775807L - old.total {
        issue.val = NumericOverflow
        raise Invalid("Int64 cumulative overflow")
      }
      { last: sample, origin: old.origin, total: old.total + sample.value, }
    }
    if index < 0 {
      lookup[sample.series] = IntSlot(records.length())
      records.push(next)
    } else {
      records[index] = next
    }
    points.push({ ..sample, start: next.origin, value: next.total, })
  }
  {
    state: {
      records,
      doubles: self.doubles,
      histograms: self.histograms,
      limit: self.limit,
      index: lookup,
    },
    points,
    duplicates,
  }
}
