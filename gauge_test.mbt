///|
fn gauge_request(value : Json) -> Json {
  {
    "resourceMetrics": [
      {
        "scopeMetrics": [
          {
            "metrics": [
              {
                "name": "temperature",
                "unit": "Cel",
                "gauge": { "dataPoints": [value] },
              },
            ],
          },
        ],
      },
    ],
  }
}

///|
test "Gauge passes unchanged with signed values and consumes no cumulative state" {
  let state = @metricstitch.State::new(max_series=1)
  let values : Array[Json] = [
    { "timeUnixNano": "2", "asInt": "-9223372036854775808" },
    { "timeUnixNano": "2", "asDouble": -1.25 },
  ]
  for value in values {
    let input = gauge_request(value)
    let first = @metricstitch.process_otlp(state, input)
    assert_eq(first.request, input)
    assert_eq(first.state.checkpoint(), state.checkpoint())
    assert_eq(first.duplicates, 0)
    assert_eq(@metricstitch.process_otlp(first.state, input).request, input)
  }
}

///|
test "Gauge malformed values and unsupported fields are rejected with location" {
  let state = @metricstitch.State::new()
  let invalid : Array[Json] = [
    { "timeUnixNano": "0", "asInt": "1" },
    { "timeUnixNano": "1", "startTimeUnixNano": "2", "asInt": "1" },
    { "timeUnixNano": "2", "asInt": "1", "asDouble": 1 },
    { "timeUnixNano": "2", "asInt": "-9223372036854775809" },
    { "timeUnixNano": "2", "asDouble": "NaN" },
    { "timeUnixNano": "2", "asInt": "1", "flags": 1 },
  ]
  for bad in invalid {
    guard @metricstitch.validate_otlp(state, gauge_request(bad)) is Some(d) else {
      fail("missing Gauge diagnostic")
    }
    assert_eq(
      d.pointer,
      "/resourceMetrics/0/scopeMetrics/0/metrics/0/gauge/dataPoints/0",
    )
  }
}

///|
test "mixed Gauge and Sum is atomic and retains all supported metrics" {
  let input = request("1", "2", "7")
  guard input
    is { "resourceMetrics": [{ "scopeMetrics": [Object(scope)], .. }], .. } &&
    scope.get("metrics") is Some(Array(metrics)) else {
    fail("fixture")
  }
  let gauge : Json = {
    "name": "temperature",
    "gauge": { "dataPoints": [{ "timeUnixNano": "2", "asDouble": -4.5 }] },
  }
  metrics.push(gauge)
  let state = @metricstitch.State::new()
  let result = @metricstitch.process_otlp(state, input)
  guard result.request
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": Array(output), .. }], .. },
      ],
      ..
    } else {
    fail("output")
  }
  assert_eq(output[1], gauge)
  assert_true(output[0].stringify().contains("\"aggregationTemporality\":2"))
  metrics[1] = {
    "name": "bad",
    "gauge": { "dataPoints": [{ "timeUnixNano": "0", "asInt": "1" }] },
  }
  let saved = state.checkpoint()
  assert_true(
    (Some(@metricstitch.process_otlp(state, input)) catch { _ => None }) is None,
  )
  assert_eq(state.checkpoint(), saved)
}
