///|
fn emitted_ints(request : Json) -> Array[String] raise {
  let values : Array[String] = []
  guard request is { "resourceMetrics": Array(resources), .. } else {
    fail("request")
  }
  for resource in resources {
    guard resource is { "scopeMetrics": Array(scopes), .. } else {
      fail("resource")
    }
    for scope in scopes {
      guard scope is { "metrics": Array(metrics), .. } else { fail("scope") }
      for metric in metrics {
        if metric is { "sum": { "dataPoints": Array(points), .. }, .. } {
          for p in points {
            if p is { "asInt": String(n), .. } {
              values.push(n)
            }
          }
        }
      }
    }
  }
  values
}

///|
test "OTLP reorder keeps metadata while recovering 3 1 2 through receipts" {
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let third = base.push(request("3", "4", "3"), watermark=1L)
  assert_true(third.request is { "resourceMetrics": [], .. })
  let first = third.buffer.push(request("1", "2", "5"), watermark=2L)
  assert_eq(emitted_ints(first.request), ["5"])
  let saved = first.buffer.checkpoint().stringify()
  let resumed = @metricstitch.decode_reorder_receipt(
      @metricstitch.parse_input(first.receipt().stringify()),
    ).buffer
  assert_eq(resumed.checkpoint().stringify(), saved)
  let failed = Some(resumed.advance(4L)) catch {
    @metricstitch.MissingInterval(_) => None
    error => raise error
  }
  assert_true(failed is None)
  let done = resumed.push(request("2", "3", "7"), watermark=4L)
  assert_eq(emitted_ints(done.request), ["12", "15"])
  assert_eq(done.buffer.pending_count(), 0)
  assert_eq(
    done.buffer.push(request("3", "4", "3"), watermark=4L).duplicates,
    1,
  )
  assert_eq(resumed.checkpoint().stringify(), saved)
  assert_eq(
    @metricstitch.decode_reorder_receipt(done.receipt()).buffer
    .state()
    .checkpoint(),
    done.buffer.state().checkpoint(),
  )
  let strict = @metricstitch.process_otlp(
      @metricstitch.State::new(),
      request("1", "2", "5"),
    ).state
  assert_true(
    (Some(@metricstitch.process_otlp(strict, request("3", "4", "3"))) catch {
      _ => None
    })
    is None,
  )
}

///|
test "OTLP reorder conflicts budgets and unsupported data preserve old buffers" {
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_pending=1,
    max_delay_ns=10L,
  )
  let held = base.push(request("3", "4", "3"), watermark=1L).buffer
  let saved = held.checkpoint()
  for
    input in [
      request("4", "5", "1"),
      request("3", "4", "4"),
      request("11", "12", "1"),
      request("2", "3", "bad"),
      { "resourceMetrics": [], "extra": true },
    ] {
    assert_true(
      (Some(held.push(input, watermark=1L)) catch { _ => None }) is None,
    )
    assert_eq(held.checkpoint(), saved)
  }
  assert_eq(held.push(request("3", "4", "3"), watermark=1L).duplicates, 1)
}

///|
test "OTLP pending payload ownership and typed checkpoint binding cannot be bypassed" {
  let input = request("2", "3", "7")
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let held = base.push(input, watermark=1L).buffer
  let saved = held.checkpoint().stringify()
  guard input
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": [Object(metric)], .. }], .. },
      ],
      ..
    } else {
    fail("input")
  }
  metric["description"] = Json("mutated")
  assert_eq(held.checkpoint().stringify(), saved)
  for
    (old, new) in [
      ("\"asInt\":\"7\"", "\"asInt\":\"8\""),
      ("\"name\":\"requests\"", "\"name\":\"other\""),
    ] {
    let changed = saved.replace_all(old~, new~)
    assert_true(changed != saved)
    assert_true(
      (Some(
        @metricstitch.OtlpReorderBuffer::restore(
          @metricstitch.parse_input(changed),
        ),
      ) catch {
        _ => None
      })
      is None,
    )
  }
  let result = held.advance(3L)
  guard result.request
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": [Object(output)], .. }], .. },
      ],
      ..
    } else {
    fail("output")
  }
  output["name"] = Json("changed output")
  assert_eq(held.checkpoint().stringify(), saved)
  assert_true(
    (Some(
      @metricstitch.OtlpReorderBuffer::restore({
        "version": 2,
        "buffer": {},
        "pending": [],
      }),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "original empty containers remain available without creating state" {
  let input : Json = {
    "resourceMetrics": [
      {
        "resource": {
          "attributes": [
            { "key": "service.name", "value": { "stringValue": "empty" } },
          ],
        },
        "schemaUrl": "https://example.com/resource-schema",
        "scopeMetrics": [],
      },
    ],
  }
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let result = base.push(input, watermark=2L)
  assert_eq(result.request, input)
  assert_eq(result.buffer.pending_count(), 0)
  assert_true(
    result.buffer.state().summary() is { "series": Number(0.0, ..), .. },
  )
}

///|
test "OTLP reordering mixes every stateful kind and passes repeated Gauges immediately" {
  let gauge = gauge_request({ "timeUnixNano": "3", "asDouble": -1.25 })
  let double = @metricstitch.parse_input(
    request("2", "3", "7")
    .stringify()
    .replace_all(old="\"requests\"", new="\"double\"")
    .replace_all(old="\"asInt\":\"7\"", new="\"asDouble\":0.25"),
  )
  let resources : Array[Json] = []
  for
    input in [
      request("2", "3", "7"),
      double,
      histogram_request("2", "3"),
      exp_request("2", "3"),
      gauge,
    ] {
    guard input is { "resourceMetrics": [resource], .. } else {
      fail("input group")
    }
    resources.push(resource)
  }
  let input : Json = { "resourceMetrics": Json::array(resources) }
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let held = base.push(input, watermark=1L)
  assert_eq(held.request, gauge)
  assert_eq(held.buffer.pending_count(), 4)
  let retry = held.buffer.push(input, watermark=1L)
  assert_eq(retry.duplicates, 4)
  assert_eq(retry.request, gauge)
  let resumed = @metricstitch.decode_reorder_receipt(retry.receipt()).buffer
  let done = resumed.advance(3L)
  assert_true(
    done.buffer.state().summary()
    is {
      "series": Number(4.0, ..),
      "int64": Number(1.0, ..),
      "double": Number(1.0, ..),
      "histogram": Number(1.0, ..),
      "exponential": Number(1.0, ..),
      ..
    },
  )
  assert_eq(
    @metricstitch.decode_reorder_receipt(done.receipt()).buffer.pending_count(),
    0,
  )
  let validated = @metricstitch.decode_receipt({
    "checkpoint": done.buffer.state().checkpoint(),
    "request": done.request,
    "duplicates": 0,
  })
  assert_eq(validated.request, done.request)
}

///|
test "OTLP buffering rejects metadata amplification before publishing a nonrecoverable state" {
  let input = request("2", "3", "1")
  guard input
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": [Object(metric)], .. }], .. },
      ],
      ..
    } &&
    metric.get("sum") is Some(Object(sum)) else {
    fail("input")
  }
  metric["description"] = Json(String::from_array(Array::make(30000, 'x')))
  sum["dataPoints"] = Json::array(
    Array::makei(70, i => {
      "startTimeUnixNano": Json((i + 2).to_string()),
      "timeUnixNano": Json((i + 3).to_string()),
      "asInt": "1",
    }),
  )
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=1000L,
  )
  let failed = Some(base.push(input, watermark=1L)) catch {
    @metricstitch.ReorderInvalid(message) => {
      assert_true(message.contains("4M"))
      None
    }
    error => raise error
  }
  assert_true(failed is None)
  assert_eq(base.pending_count(), 0)
}

///|
test "all three-interval permutations yield the same OTLP output and checkpoint" {
  let inputs = [
    request("1", "2", "5"),
    request("2", "3", "7"),
    request("3", "4", "3"),
  ]
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let expected = base.push(inputs[0], watermark=1L).buffer.push(
    inputs[1],
    watermark=1L,
  ).buffer.push(inputs[2], watermark=4L)
  for
    indexes in [
      [0, 1, 2],
      [0, 2, 1],
      [1, 0, 2],
      [1, 2, 0],
      [2, 0, 1],
      [2, 1, 0],
    ] {
    let mut buffer = base
    for i in indexes {
      buffer = buffer.push(inputs[i], watermark=1L).buffer
    }
    let result = buffer.advance(4L)
    assert_eq(result.request, expected.request)
    assert_eq(result.buffer.checkpoint(), expected.buffer.checkpoint())
  }
}
