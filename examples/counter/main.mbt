///|
fn main raise {
  let first : @metricstitch.Sample = {
    series: "requests",
    start: 1L,
    end: 2L,
    value: 7L,
  }
  let next : @metricstitch.Sample = { ..first, start: 2L, end: 3L, value: 5L, }
  let result = @metricstitch.State::new().apply([first, next])
  println(result.points[1].value)
}
