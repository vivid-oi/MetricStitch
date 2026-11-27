///|
fn main raise {
  // Population/buckets are adapted from the pinned official OTLP example.
  let epoch = 1544712660000000000L
  let first : @metricstitch.ExponentialSample = {
    series: "latency",
    start: epoch,
    end: epoch + 1000000000L,
    scale: 0,
    zero_count: 1L,
    zero_threshold: 0.0,
    positive: { offset: 1, counts: [0L, 2L], },
    negative: { offset: 0, counts: [], },
    count: 3L,
    sum: Some(10.0),
    min: Some(0.0),
    max: Some(5.0),
  }
  let saved = @metricstitch.State::new().apply_exponentials([first]).state.checkpoint()
  let resumed = @metricstitch.State::restore(saved)
  let second = {
    ..first,
    start: first.end,
    end: first.end + 1000000000L,
    scale: 1,
    positive: { offset: 4, counts: [2L], },
  }
  let result = resumed.apply_exponentials([second])
  assert_eq(result.points[0].scale, 0)
  assert_eq(result.points[0].positive.offset, 2)
  assert_eq(result.points[0].positive.counts, [4L])
  assert_eq(result.points[0].zero_count, 2L)
  assert_eq(result.points[0].count, 6L)
  assert_eq(result.points[0].sum, Some(20.0))
  assert_eq(result.state.apply_exponentials([second]).duplicates, 1)
  println(
    "Exponential histogram: scales 0/1 aligned to 0; count 6, zero 2, positive 4, sum 20; checkpoint/retry verified",
  )
}
