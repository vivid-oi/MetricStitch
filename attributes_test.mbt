///|
fn with_attribute(value : Json) -> Json {
  let source = request("1", "2", "7")
  guard source
    is {
      "resourceMetrics": [
        {
          "scopeMetrics": [
            {
              "metrics": [{ "sum": { "dataPoints": [Object(point)], .. }, .. }],
              ..
            },
          ],
          ..
        },
      ],
      ..
    } else {
    abort("invalid test fixture")
  }
  point["attributes"] = [{ "key": "typed", "value": value }]
  source
}

///|
test "AnyValue kinds preserve identity type and exact integers" {
  let state = @metricstitch.State::new()
  let values : Array[Json] = [
    { "stringValue": "true" },
    { "boolValue": true },
    { "intValue": "-9223372036854775808" },
    { "intValue": "9007199254740993" },
    { "doubleValue": 1.25 },
    { "bytesValue": "AAE=" },
    { "arrayValue": { "values": [{ "intValue": "1" }, { "boolValue": true }] } },
    {
      "kvlistValue": {
        "values": [{ "key": "nested", "value": { "stringValue": "v" } }],
      },
    },
  ]
  let mut current = state
  for value in values {
    let input = with_attribute(value)
    let step = @metricstitch.process_otlp(current, input)
    assert_eq(step.duplicates, 0)
    assert_true(step.request.stringify().contains(value.stringify()))
    assert_eq(
      @metricstitch.process_otlp(
        @metricstitch.State::restore(step.state.checkpoint()),
        input,
      ).duplicates,
      1,
    )
    current = step.state
  }
  let first = @metricstitch.process_otlp(
    state,
    with_attribute({ "intValue": "01" }),
  )
  assert_eq(
    @metricstitch.process_otlp(first.state, with_attribute({ "intValue": "1" })).duplicates,
    1,
  )
}

///|
test "malformed AnyValue is rejected before committing state" {
  let state = @metricstitch.State::new()
  let before = state.checkpoint()
  for
    bad in [
      Json::empty_object(),
      { "stringValue": "x", "boolValue": true },
      { "boolValue": "true" },
      { "intValue": "9223372036854775808" },
      { "intValue": 1 },
      { "bytesValue": "!" },
      { "doubleValue": "NaN" },
      {
        "kvlistValue": {
          "values": [
            { "key": "x", "value": { "intValue": "1" } },
            { "key": "x", "value": { "intValue": "2" } },
          ],
        },
      },
    ] {
    assert_true(
      (Some(@metricstitch.process_otlp(state, with_attribute(bad))) catch {
        _ => None
      })
      is None,
    )
  }
  let mut nested : Json = { "stringValue": "x" }
  for _ in 0..<18 {
    nested = { "arrayValue": { "values": [nested] } }
  }
  assert_true(
    (Some(@metricstitch.process_otlp(state, with_attribute(nested))) catch {
      _ => None
    })
    is None,
  )
  assert_eq(state.checkpoint(), before)
}
