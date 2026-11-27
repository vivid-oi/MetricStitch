///|
/// Both states retain the original capacity. Archive persistence and routing of
/// delayed points are the caller's responsibility.
pub(all) struct Partition {
  retained : State
  archived : State
}

///|
/// Return a detached summary of capacity, kinds and most-recent end timestamps.
pub fn State::summary(self : State) -> Json {
  let ends : Array[Int64] = []
  for r in self.records {
    ends.push(r.last.end)
  }
  for r in self.doubles {
    ends.push(r.last.end)
  }
  for r in self.histograms {
    ends.push(r.last_hist.end)
  }
  for r in self.exponentials {
    ends.push(r.last_exp.end)
  }
  ends.sort()
  let result : Json = {
    "series": Json(ends.length()),
    "capacity": Json(self.limit),
    "available": Json(self.limit - ends.length()),
    "int64": Json(self.records.length()),
    "double": Json(self.doubles.length()),
    "histogram": Json(self.histograms.length()),
    "oldest_end": match ends.get(0) {
      Some(n) => Json(n.to_string())
      None => null
    },
    "newest_end": match ends.last() {
      Some(n) => Json(n.to_string())
      None => null
    },
  }
  if !self.exponentials.is_empty() && result is Object(obj) {
    obj["exponential"] = Json(self.exponentials.length())
  }
  result
}

///|
/// Partition by last.end < cutoff, expressed as positive Unix nanoseconds.
/// No clock is read and no series is discarded. Reintroducing an archived series
/// to retained starts a new cumulative origin. Route delayed points to archived
/// when its previous cumulative history must continue.
///
/// ```mbt check
/// test {
///   let p : @metricstitch.Sample = {
///     series: "requests",
///     start: 1L,
///     end: 2L,
///     value: 7L,
///   }
///   let state = @metricstitch.State::new().apply([p]).state
///   let split = state.partition_before(3L)
///   assert_eq(split.archived.checkpoint(), state.checkpoint())
/// }
/// ```
pub fn State::partition_before(
  self : State,
  cutoff : Int64,
) -> Partition raise StitchError {
  if cutoff <= 0L {
    raise Invalid("cutoff must be positive Unix nanoseconds")
  }
  let retained = indexed_state(
    self.records.filter(r => r.last.end >= cutoff),
    self.doubles.filter(r => r.last.end >= cutoff),
    self.histograms.filter(r => r.last_hist.end >= cutoff),
    self.limit,
    exponentials=self.exponentials.filter(r => r.last_exp.end >= cutoff),
  )
  let archived = indexed_state(
    self.records.filter(r => r.last.end < cutoff),
    self.doubles.filter(r => r.last.end < cutoff),
    self.histograms.filter(r => r.last_hist.end < cutoff),
    self.limit,
    exponentials=self.exponentials.filter(r => r.last_exp.end < cutoff),
  )
  { retained, archived, }
}
