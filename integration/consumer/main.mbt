///|
fn main raise {
  let first : @metricstitch.Sample = {
    series: "http.requests",
    start: 1L,
    end: 2L,
    value: 5L,
  }
  let saved = @metricstitch.State::new().apply([first]).state.checkpoint()
  let restored = @metricstitch.State::restore(saved)
  assert_eq(restored.apply([first]).duplicates, 1)
  let next = restored.apply([{ ..first, start: 2L, end: 3L, value: 7L, }])
  assert_eq(next.points[0].value, 12L)
  println("External module: restored counter = 12; retry suppressed")
}
