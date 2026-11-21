///|
test "indexed diagnostics identify points and retain conversion semantics" {
  let state = @metricstitch.State::new()
  let input = histogram_request("1", "2")
  let first = @metricstitch.process_otlp(state, input)
  let saved = first.state.checkpoint()
  let bad = histogram_request("3", "4")
  guard @metricstitch.validate_otlp(first.state, bad) is Some(d) else {
    fail("missing diagnostic")
  }
  assert_eq(
    d.pointer,
    "/resourceMetrics/0/scopeMetrics/0/metrics/0/histogram/dataPoints/0",
  )
  assert_true(d.message.contains("noncontiguous"))
  assert_true(
    (Some(@metricstitch.process_otlp(first.state, bad)) catch { _ => None })
    is None,
  )
  assert_true(
    @metricstitch.validate_otlp(first.state, histogram_request("2", "3"))
    is None,
  )
  assert_eq(first.state.checkpoint(), saved)
  guard @metricstitch.validate_otlp(state, { "unexpected": 1 }) is Some(root) else {
    fail("missing root error")
  }
  assert_eq(root.pointer, "")
}
