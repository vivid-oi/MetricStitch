///|
/// Reattach disjoint archived/sharded states without adding their totals.
/// The destination's capacity is authoritative. Any overlapping identity,
/// including an identical record or a different kind, is refused atomically.
/// Origins, most-recent deltas and checkpoint versions are preserved.
///
/// ```mbt check
/// test {
///   let a : @metricstitch.Sample = { series: "a", start: 1L, end: 2L, value: 5L, }
///   let b = { ..a, series: "b", }
///   let left = @metricstitch.State::new().apply([a]).state
///   let right = @metricstitch.State::new().apply([b]).state
///   let joined = left.merge_disjoint(right)
///   assert_eq(joined.apply([a, b]).duplicates, 2)
/// }
/// ```
pub fn State::merge_disjoint(
  self : State,
  other : State,
) -> State raise StitchError {
  for series in other.index.keys() {
    if self.index.contains(series) {
      raise Invalid("cannot merge overlapping series: " + series)
    }
  }
  if other.index.length() > self.limit - self.index.length() {
    raise Invalid("merged state exceeds destination series capacity")
  }
  indexed_state(
    self.records + other.records,
    self.doubles + other.doubles,
    self.histograms + other.histograms,
    self.limit,
    exponentials=self.exponentials + other.exponentials,
  )
}
