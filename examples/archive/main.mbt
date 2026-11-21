///|
fn main raise {
  let old : @metricstitch.Sample = {
    series: "old-worker",
    start: 1L,
    end: 2L,
    value: 7L,
  }
  let recent : @metricstitch.Sample = {
    series: "current-worker",
    start: 3L,
    end: 4L,
    value: 5L,
  }
  let state = @metricstitch.State::new(max_series=2).apply([old, recent]).state
  let partition = state.partition_before(3L)
  let archived = @metricstitch.State::restore(partition.archived.checkpoint())
  assert_eq(archived.apply([old]).duplicates, 1)
  println(partition.retained.summary().stringify())
  println(partition.archived.checkpoint().stringify())
}
