///|
fn request(start : String, end : String, value : String) -> Json {
  {
    "resourceMetrics": [
      {
        "resource": {
          "attributes": [
            { "key": "service.name", "value": { "stringValue": "test" } },
          ],
        },
        "scopeMetrics": [
          {
            "scope": { "name": "demo" },
            "metrics": [
              {
                "name": "requests",
                "sum": {
                  "aggregationTemporality": 1,
                  "isMonotonic": true,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": Json(start),
                      "timeUnixNano": Json(end),
                      "asInt": Json(value),
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
test "OTLP conversion recovery and rejection are transactional" {
  let empty = @metricstitch.State::new()
  let input = request("1", "2", "7")
  let saved = input.stringify()
  let first = @metricstitch.process_otlp(empty, input)
  assert_eq(input.stringify(), saved)
  let resumed = @metricstitch.State::restore(first.state.checkpoint())
  let second = @metricstitch.process_otlp(resumed, request("2", "3", "5"))
  assert_true(second.request.stringify().contains("\"asInt\":\"12\""))
  assert_true(
    second.request.stringify().contains("\"aggregationTemporality\":2"),
  )
  assert_eq(@metricstitch.process_otlp(resumed, input).duplicates, 1)
  assert_true(
    (Some(@metricstitch.process_otlp(resumed, request("3", "4", "1"))) catch {
      _ => None
    })
    is None,
  )
  for
    bad in [
      Json::null(),
      { "resourceMetrics": [], "extension": true },
      request("2", "3", "1_0"),
      request("2", "3", "9223372036854775808"),
    ] {
    assert_true(
      (Some(@metricstitch.process_otlp(resumed, bad)) catch { _ => None })
      is None,
    )
  }
  assert_eq(
    @metricstitch.process_otlp(resumed, request("2", "3", "5")).request,
    second.request,
  )
}

///|
test "unsupported point kinds cannot be coerced and attribute order is stable" {
  let state = @metricstitch.State::new()
  let source = request("1", "2", "7").stringify()
  for
    bad in [
      source.replace(old="\"asInt\"", new="\"asDouble\""),
      source.replace(old="\"isMonotonic\":true", new="\"isMonotonic\":false"),
      source.replace(
        old="\"aggregationTemporality\":1",
        new="\"aggregationTemporality\":2",
      ),
    ] {
    assert_true(
      (Some(@metricstitch.process_otlp(state, @metricstitch.parse_input(bad))) catch {
        _ => None
      })
      is None,
    )
  }
  let a = "{\"key\":\"a\",\"value\":{\"stringValue\":\"1\"}}"
  let b = "{\"key\":\"b\",\"value\":{\"stringValue\":\"2\"}}"
  let old = "\"startTimeUnixNano\""
  let forward = source.replace(
    old~,
    new="\"attributes\":[" + a + "," + b + "]," + old,
  )
  let reverse = source.replace(
    old~,
    new="\"attributes\":[" + b + "," + a + "]," + old,
  )
  let first = @metricstitch.process_otlp(
    state,
    @metricstitch.parse_input(forward),
  )
  assert_eq(
    @metricstitch.process_otlp(first.state, @metricstitch.parse_input(reverse)).duplicates,
    1,
  )
}
