///|
/// A nonnegative finite Double delta. Accumulation uses IEEE-754 addition.
#derive(Eq)
pub(all) struct DoubleSample {
  series : String
  start : Int64
  end : Int64
  value : Double
}

///|
pub extend DoubleSample with Eq::{equal, not_equal}

///|
priv struct DoubleRecord {
  last : DoubleSample
  origin : Int64
  total : Double
}

///|
pub(all) struct DoubleStep {
  state : State
  points : Array[DoubleSample]
  duplicates : Int32
}

///|
fn finite_nonnegative(value : Json) -> Double raise StitchError {
  guard value is Number(number, ..) &&
    !number.is_nan() &&
    !number.is_inf() &&
    number >= 0.0 else {
    raise Invalid("expected finite nonnegative Double")
  }
  if number == 0.0 {
    0.0
  } else {
    number
  }
}

///|
/// Apply finite Double deltas with the same interval and retry rules as apply.
/// Numeric-kind switches are rejected. State is committed only on success.
///
/// ```mbt check
/// test {
///   let p : @metricstitch.DoubleSample = {
///     series: "duration",
///     start: 1L,
///     end: 2L,
///     value: 1.25,
///   }
///   let first = @metricstitch.State::new().apply_doubles([p])
///   assert_eq(first.state.apply_doubles([p]).duplicates, 1)
/// }
/// ```
pub fn State::apply_doubles(
  self : State,
  batch : Array[DoubleSample],
) -> DoubleStep raise StitchError {
  self.apply_double_impl(batch, Ref(InvalidInput))
}

///|
fn State::apply_double_impl(
  self : State,
  batch : Array[DoubleSample],
  issue : Ref[IssueCode],
  writable~ : Bool = false,
) -> DoubleStep raise StitchError {
  let records = if writable { self.doubles } else { self.doubles.copy() }
  let lookup = if writable { self.index } else { self.index.copy() }
  let points = []
  let mut duplicates = 0
  for sample in batch {
    if sample.series.is_empty() ||
      sample.series.length() > 65536 ||
      sample.start <= 0L ||
      sample.end <= sample.start {
      raise Invalid("expected bounded series and positive increasing interval")
    }
    ignore(finite_nonnegative(Json(sample.value)))
    let slot = lookup.get(sample.series)
    if slot is Some(IntSlot(_) | HistogramSlot(_)) {
      issue.val = KindChanged
      raise Invalid("series changed numeric kind")
    }
    let index = match slot {
      Some(DoubleSlot(i)) => i
      _ => -1
    }
    let next : DoubleRecord = if index < 0 {
      if records.length() + self.records.length() + self.histograms.length() ==
        self.limit {
        issue.val = SeriesLimit
        raise Invalid("series limit exceeded")
      }
      { last: sample, origin: sample.start, total: sample.value, }
    } else {
      let old = records[index]
      if old.last == sample {
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
        raise Invalid("noncontiguous Double interval for " + sample.series)
      }
      let total = old.total + sample.value
      if total.is_inf() {
        issue.val = NumericOverflow
        raise Invalid("Double cumulative overflow")
      }
      { last: sample, origin: old.origin, total, }
    }
    if index < 0 {
      lookup[sample.series] = DoubleSlot(records.length())
      records.push(next)
    } else {
      records[index] = next
    }
    points.push({ ..sample, start: next.origin, value: next.total, })
  }
  {
    state: {
      records: self.records,
      doubles: records,
      histograms: self.histograms,
      limit: self.limit,
      index: lookup,
    },
    points,
    duplicates,
  }
}

///|
fn restore_doubles(value : Json) -> State raise StitchError {
  let obj = fields(
    value,
    ["version", "max_series", "records", "doubles"],
    "checkpoint",
  )
  let base = State::restore({
    "version": 1,
    "max_series": required(obj, "max_series"),
    "records": required(obj, "records"),
  })
  let items = array(required(obj, "doubles"), "doubles")
  if items.length() > base.limit - base.records.length() {
    raise Invalid("checkpoint exceeds series limit")
  }
  let doubles : Array[DoubleRecord] = []
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let r = fields(
      item,
      ["series", "start", "end", "delta", "origin", "total"],
      "Double record",
    )
    let series = text(required(r, "series"), "series")
    if seen.contains(series) {
      raise Invalid("duplicate Double checkpoint series")
    }
    seen[series] = true
    let last : DoubleSample = {
      series,
      start: decimal(required(r, "start"), "start"),
      end: decimal(required(r, "end"), "end"),
      value: finite_nonnegative(required(r, "delta")),
    }
    if base.index.contains(series) {
      raise Invalid("series changed numeric kind")
    }
    ignore(State::new().apply_doubles([last]))
    let origin = decimal(required(r, "origin"), "origin")
    let total = finite_nonnegative(required(r, "total"))
    if origin <= 0L ||
      origin > last.start ||
      total < last.value ||
      (origin == last.start && total != last.value) {
      raise Invalid("Double checkpoint contradicts its last delta")
    }
    doubles.push({ last, origin, total, })
  }
  indexed_state(base.records, doubles, [], base.limit)
}
