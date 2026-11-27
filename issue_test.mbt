///|
test "structured diagnoses classify at source and preserve legacy failures" {
  let initial = @metricstitch.State::new(max_series=1)
  let first = @metricstitch.process_otlp(initial, request("1", "2", "7"))
  let other = @metricstitch.parse_input(
    request("2", "3", "1").stringify().replace_all(old="requests", new="other"),
  )
  let cases = [
    (request("3", "4", "1"), "noncontiguous_interval"),
    (request("1", "2", "8"), "conflicting_retry"),
    (request("2", "3", "9223372036854775807"), "numeric_overflow"),
    (request("2", "3", "bad"), "invalid_input"),
    (other, "series_limit"),
    ({ "resourceMetrics": [], "extra": true }, "unsupported_data"),
    (
      @metricstitch.parse_input(
        request("2", "3", "1")
        .stringify()
        .replace_all(old="\"asInt\":\"1\"", new="\"asDouble\":1.0"),
      ),
      "kind_changed",
    ),
  ]
  let saved = first.state.checkpoint()
  for (input, code) in cases {
    guard @metricstitch.diagnose_otlp(first.state, input) is Some(detail) else {
      fail("missing detail")
    }
    assert_eq(detail.code.code(), code)
    guard @metricstitch.validate_otlp(first.state, input) is Some(legacy) else {
      fail("missing legacy diagnostic")
    }
    assert_eq(detail.message, legacy.message)
    assert_eq(detail.pointer, legacy.pointer)
    let message = @metricstitch.process_otlp(first.state, input) catch {
      @metricstitch.Invalid(message) => {
        assert_true(message.contains(detail.message))
        continue
      }
    }
    ignore(message)
    fail("expected legacy Invalid")
  }
  assert_eq(first.state.checkpoint(), saved)
  assert_true(
    @metricstitch.diagnose_otlp(first.state, request("2", "3", "1")) is None,
  )
}

///|
test "structured histogram errors distinguish layouts and invalid populations" {
  let state = @metricstitch.process_otlp(
      @metricstitch.State::new(),
      histogram_request("1", "2"),
    ).state
  let changed = histogram_request("2", "3")
    .stringify()
    .replace_all(old="\"explicitBounds\":[1", new="\"explicitBounds\":[2")
  guard @metricstitch.diagnose_otlp(state, @metricstitch.parse_input(changed))
    is Some(d) else {
    fail("missing changed layout")
  }
  assert_eq(d.code.code(), "kind_changed")
  guard @metricstitch.diagnose_otlp(state, histogram_request("4", "5"))
    is Some(gap) else {
    fail("missing gap")
  }
  assert_eq(gap.code.code(), "noncontiguous_interval")
}
