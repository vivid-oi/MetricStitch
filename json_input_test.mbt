///|
test "duplicate escaped keys malformed JSON and deep inputs are rejected" {
  for
    bad in [
      "{", "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"outer\":[{\"a\":1,\"a\":2}]}",
    ] {
    assert_true(
      (Some(@metricstitch.parse_input(bad)) catch { _ => None }) is None,
    )
  }
  let valid = "{\"a\":\"quote \\\" and : }\",\"b\":[{\"a\":1},{\"a\":2}]}"
  let parsed = @metricstitch.parse_input(valid)
  assert_eq(@metricstitch.parse_input(parsed.stringify()), parsed)
}
