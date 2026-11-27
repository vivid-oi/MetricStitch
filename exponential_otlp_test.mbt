///|
fn exp_request(start : String, end : String, scale~ : Json = Json(2)) -> Json {
  {
    "resourceMetrics": [
      {
        "resource": {
          "attributes": [
            {
              "key": "service.name",
              "value": { "stringValue": "exponential-test" },
            },
          ],
        },
        "scopeMetrics": [
          {
            "scope": { "name": "test" },
            "metrics": [
              {
                "name": "latency",
                "unit": "s",
                "description": "both signs and zero",
                "exponentialHistogram": {
                  "aggregationTemporality": 1,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": Json(start),
                      "timeUnixNano": Json(end),
                      "attributes": [
                        { "key": "route", "value": { "stringValue": "/" } },
                      ],
                      "count": "5",
                      "zeroCount": "1",
                      "scale": scale,
                      "positive": { "offset": -1, "bucketCounts": ["1", "1"] },
                      "negative": { "offset": 0, "bucketCounts": ["2"] },
                    },
                  ],
                },
              },
            ],
          },
        ],
      },
    ],
  }
}

///|
test "exponential OTLP preserves metadata and restores mixed receipts" {
  let empty = @metricstitch.State::new()
  let input = exp_request("1", "2")
  let before = input.stringify()
  let first = @metricstitch.process_otlp(empty, input)
  let restored = @metricstitch.decode_receipt(first.receipt())
  assert_eq(restored.state.checkpoint(), first.state.checkpoint())
  let second = @metricstitch.process_otlp(
    restored.state,
    exp_request("2", "3", scale=Json(0)),
  )
  assert_true(
    second.request
    is {
      "resourceMetrics": [
        {
          "scopeMetrics": [
            {
              "metrics": [
                {
                  "description": String("both signs and zero"),
                  "exponentialHistogram": {
                    "aggregationTemporality": Number(2.0, ..),
                    "dataPoints": [
                      {
                        "count": String("10"),
                        "zeroCount": String("2"),
                        "scale": Number(0.0, ..),
                        "attributes": [{ "key": String("route"), .. }],
                        ..
                      },
                    ],
                    ..
                  },
                  ..
                },
              ],
              ..
            },
          ],
          ..
        },
      ],
      ..
    },
  )
  assert_eq(input.stringify(), before)
  assert_eq(@metricstitch.process_otlp(restored.state, input).duplicates, 1)
  assert_eq(
    @metricstitch.decode_receipt(second.receipt()).state.checkpoint(),
    second.state.checkpoint(),
  )
  let mixed = @metricstitch.process_otlp(second.state, request("1", "2", "7"))
  assert_eq(
    @metricstitch.State::restore(mixed.state.checkpoint()).checkpoint(),
    mixed.state.checkpoint(),
  )
}

///|
test "exponential JSON malformed scales flags and threshold changes reject safely" {
  let state = @metricstitch.process_otlp(
      @metricstitch.State::new(),
      exp_request("1", "2"),
    ).state
  let saved = state.checkpoint()
  for scale in [Json(2.5), Json("2"), Json(21), Json(-11)] {
    assert_true(
      @metricstitch.diagnose_otlp(state, exp_request("2", "3", scale~))
      is Some(_),
    )
  }
  let bad = @metricstitch.parse_input(
    exp_request("2", "3")
    .stringify()
    .replace_all(old="\"scale\":2", new="\"scale\":2,\"zeroThreshold\":0.5"),
  )
  guard @metricstitch.diagnose_otlp(state, bad) is Some(d) else {
    fail("missing threshold diagnostic")
  }
  assert_eq(d.code.code(), "kind_changed")
  assert_eq(
    d.pointer,
    "/resourceMetrics/0/scopeMetrics/0/metrics/0/exponentialHistogram/dataPoints/0",
  )
  assert_eq(state.checkpoint(), saved)
  let nested = @metricstitch.parse_input(
    exp_request("2", "3")
    .stringify()
    .replace_all(old="\"offset\":-1", new="\"offset\":-1,\"extra\":true"),
  )
  guard @metricstitch.diagnose_otlp(state, nested) is Some(extra) else {
    fail("missing nested field diagnostic")
  }
  assert_eq(extra.code.code(), "unsupported_data")
}
