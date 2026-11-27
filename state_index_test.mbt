///|
test "indexed large batches preserve ordering independence restoration and old state" {
  let points : Array[@metricstitch.Sample] = []
  for i in 0..<10000 {
    points.push({
      series: "series-" + i.to_string(),
      start: 1L,
      end: 2L,
      value: i.to_int64(),
    })
  }
  let empty = @metricstitch.State::new(max_series=10000)
  let first = empty.apply(points)
  let saved = first.state.checkpoint().stringify()
  let reversed = Array::makei(points.length(), i => {
    points[points.length() - 1 - i]
  })
  assert_eq(empty.apply(reversed).state.checkpoint().stringify(), saved)
  let restored = @metricstitch.State::restore(@metricstitch.parse_input(saved))
  assert_eq(restored.apply(reversed).duplicates, 10000)
  let next = restored.apply(points.map(p => { ..p, start: 2L, end: 3L, }))
  for i, point in next.points {
    assert_eq(point.value, 2L * i.to_int64())
  }
  assert_eq(restored.checkpoint().stringify(), saved)
  assert_eq(first.state.checkpoint().stringify(), saved)
  assert_true(empty.summary() is { "series": Number(0.0, ..), .. })
  let bad = points.map(p => { ..p, start: 2L, end: 3L, })
  bad.push({ series: "extra", start: 2L, end: 3L, value: 1L, })
  assert_true((Some(restored.apply(bad)) catch { _ => None }) is None)
  assert_eq(restored.checkpoint().stringify(), saved)
}

///|
test "OTLP private transaction equals public per-request execution and rolls back late errors" {
  let requests = Array::makei(128, i => {
    @metricstitch.parse_input(
      request("1", "2", "7")
      .stringify()
      .replace_all(old="\"requests\"", new="\"metric-" + i.to_string() + "\""),
    )
  })
  let state = @metricstitch.State::new()
  let mut expected = state
  let resources : Array[Json] = []
  for input in requests {
    expected = @metricstitch.process_otlp(expected, input).state
    guard input is { "resourceMetrics": [r], .. } else { fail("input") }
    resources.push(r)
  }
  let combined : Json = { "resourceMetrics": Json::array(resources) }
  let step = @metricstitch.process_otlp(state, combined)
  assert_eq(step.state.checkpoint(), expected.checkpoint())
  assert_eq(@metricstitch.process_otlp(step.state, combined).duplicates, 128)
  let saved = step.state.checkpoint()
  resources.push({ "unknown": true })
  assert_true(
    (Some(@metricstitch.process_otlp(state, combined)) catch { _ => None })
    is None,
  )
  assert_eq(step.state.checkpoint(), saved)
  assert_true(state.summary() is { "series": Number(0.0, ..), .. })
}
