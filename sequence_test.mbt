///|
test "sequence equals sequential conversion and retains duplicate accounting" {
  let state = @metricstitch.State::new()
  let a = request("1", "2", "7")
  let b = request("2", "3", "5")
  let first = @metricstitch.process_otlp(state, a)
  let second = @metricstitch.process_otlp(first.state, b)
  let sequence = @metricstitch.process_sequence(state, [a, a, b])
  assert_eq(sequence.duplicates, 1)
  assert_eq(sequence.state.checkpoint(), second.state.checkpoint())
  guard sequence.request is { "resourceMetrics": Array(groups), .. } &&
    first.request is { "resourceMetrics": [one], .. } &&
    second.request is { "resourceMetrics": [two], .. } else {
    fail("shape")
  }
  assert_eq(groups.length(), 3)
  assert_eq(groups[0], one)
  assert_eq(groups[2], two)
  assert_eq(
    @metricstitch.process_sequence(state, [a, a, b]).request,
    sequence.request,
  )
  assert_eq(
    @metricstitch.process_sequence(
      @metricstitch.State::restore(first.state.checkpoint()),
      [a, b],
    ).state.checkpoint(),
    second.state.checkpoint(),
  )
}

///|
test "late sequence errors are indexed and original state remains usable" {
  let state = @metricstitch.State::new()
  let saved = state.checkpoint()
  let message = try
    @metricstitch.process_sequence(state, [
      request("1", "2", "7"),
      request("3", "4", "5"),
    ])
  catch {
    @metricstitch.Invalid(message) => message
  } noraise {
    _ => "unexpected success"
  }
  assert_true(message.has_prefix("/requests/1/resourceMetrics/0/"))
  assert_eq(state.checkpoint(), saved)
  assert_eq(@metricstitch.process_sequence(state, []).state.checkpoint(), saved)
  let large = Array::make(1025, Json::null())
  assert_true(
    (Some(@metricstitch.process_sequence(state, large)) catch { _ => None })
    is None,
  )
}

///|
test "sequence retains mixed histogram and Gauge groups across recovery" {
  let state = @metricstitch.State::new()
  let gauge = gauge_request({ "timeUnixNano": "2", "asDouble": -2.0 })
  let first = @metricstitch.process_sequence(state, [
    histogram_request("1", "2"),
    gauge,
  ])
  let second = @metricstitch.process_sequence(
    @metricstitch.State::restore(first.state.checkpoint()),
    [histogram_request("2", "3"), gauge],
  )
  assert_true(second.request.stringify().contains("\"count\":\"4\""))
  assert_eq(
    @metricstitch.State::restore(second.state.checkpoint()).checkpoint(),
    second.state.checkpoint(),
  )
}
