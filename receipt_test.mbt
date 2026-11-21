///|
test "receipts round trip mixed historical output and all checkpoint versions" {
  let state = @metricstitch.State::new()
  let integer = @metricstitch.process_sequence(state, [
    request("1", "2", "7"),
    request("2", "3", "5"),
  ])
  let floating = @metricstitch.process_otlp(
    state,
    @metricstitch.parse_input(
      request("1", "2", "7")
      .stringify()
      .replace(old="\"asInt\":\"7\"", new="\"asDouble\":1.25"),
    ),
  )
  let histogram = @metricstitch.process_otlp(state, histogram_request("1", "2"))
  for step in [integer, floating, histogram] {
    let receipt = step.receipt()
    let restored = @metricstitch.decode_receipt(
      @metricstitch.parse_input(receipt.stringify()),
    )
    assert_eq(restored.receipt(), receipt)
  }
  let continued = @metricstitch.process_otlp(
    @metricstitch.decode_receipt(integer.receipt()).state,
    request("3", "4", "2"),
  )
  assert_true(continued.request.stringify().contains("\"asInt\":\"14\""))
}

///|
test "receipt rejects malformed output profile and invalid duplicate count" {
  let empty = @metricstitch.State::new().checkpoint()
  let invalid : Array[Json] = [
    { "checkpoint": empty, "request": {}, "duplicates": 0 },
    { "checkpoint": empty, "request": request("1", "2", "7"), "duplicates": 0 },
    {
      "checkpoint": empty,
      "request": { "resourceMetrics": [] },
      "duplicates": -1,
    },
    {
      "checkpoint": empty,
      "request": { "resourceMetrics": [] },
      "duplicates": 0.5,
    },
    {
      "checkpoint": empty,
      "request": { "resourceMetrics": [] },
      "duplicates": 2147483648.0,
    },
    {
      "checkpoint": empty,
      "request": { "resourceMetrics": [] },
      "duplicates": 0,
      "extra": true,
    },
  ]
  for bad in invalid {
    assert_true(
      (Some(@metricstitch.decode_receipt(bad)) catch { _ => None }) is None,
    )
  }
}
