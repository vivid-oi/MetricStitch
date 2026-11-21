///|
test "checkpoint round trip resumes exact large values" {
  let p : @metricstitch.Sample = {
    series: "r",
    start: 9007199254740993L,
    end: 9007199254740994L,
    value: 9007199254740993L,
  }
  let state = @metricstitch.State::new().apply([p]).state
  let saved = state.checkpoint()
  let restored = @metricstitch.State::restore(saved)
  assert_eq(restored.checkpoint(), saved)
  let next : @metricstitch.Sample = {
    ..p,
    start: p.end,
    end: p.end + 1L,
    value: 5L,
  }
  assert_true(restored.apply([next]).points == state.apply([next]).points)
  assert_eq(restored.apply([p]).duplicates, 1)
}

///|
test "malformed checkpoint cannot poison the original state" {
  for
    bad in [
      Json::null(),
      { "version": 2 },
      { "version": 1, "max_series": "0", "records": [] },
      { "version": 1, "max_series": "1_0", "records": [] },
      { "version": 1, "max_series": "1", "records": [], "unknown": true },
    ] {
    assert_true(
      (Some(@metricstitch.State::restore(bad)) catch { _ => None }) is None,
    )
  }
  let a : @metricstitch.Sample = { series: "a", start: 1L, end: 2L, value: 0L, }
  let b : @metricstitch.Sample = { ..a, series: "b", }
  let state = @metricstitch.State::new()
  assert_eq(
    state.apply([a, b]).state.checkpoint(),
    state.apply([b, a]).state.checkpoint(),
  )
}
