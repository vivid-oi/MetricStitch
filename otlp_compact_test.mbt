///|
fn compact_fixture() -> Json {
  {
    "resourceMetrics": [
      {
        "resource": {
          "attributes": [
            { "key": "service.name", "value": { "stringValue": "checkout" } },
          ],
        },
        "schemaUrl": "https://example.com/resource/v1",
        "scopeMetrics": [
          {
            "scope": { "name": "sdk", "version": "1" },
            "schemaUrl": "https://example.com/scope/v1",
            "metrics": [
              {
                "name": "requests",
                "description": "orders",
                "unit": "1",
                "sum": {
                  "aggregationTemporality": 2,
                  "isMonotonic": true,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": "1",
                      "timeUnixNano": "2",
                      "asInt": "9007199254740993",
                    },
                  ],
                },
              },
              {
                "name": "seconds",
                "sum": {
                  "aggregationTemporality": 2,
                  "isMonotonic": true,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": "1",
                      "timeUnixNano": "2",
                      "asDouble": 0.5,
                    },
                  ],
                },
              },
              {
                "name": "latency",
                "histogram": {
                  "aggregationTemporality": 2,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": "1",
                      "timeUnixNano": "2",
                      "count": "2",
                      "bucketCounts": ["1", "1"],
                      "explicitBounds": [1],
                    },
                  ],
                },
              },
              {
                "name": "distribution",
                "exponentialHistogram": {
                  "aggregationTemporality": 2,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": "1",
                      "timeUnixNano": "2",
                      "scale": 0,
                      "count": "2",
                      "zeroCount": "1",
                      "positive": { "offset": -1, "bucketCounts": ["1"] },
                    },
                  ],
                },
              },
              {
                "name": "temperature",
                "gauge": {
                  "dataPoints": [
                    { "timeUnixNano": "2", "asInt": "-9223372036854775808" },
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
// Flatten complete envelopes in traversal order; include empty-container events.
// This oracle checks data/order conservation independently of the merge routine.
fn compact_rows(value : Json) -> Array[String] raise {
  let rows : Array[String] = []
  guard value is { "resourceMetrics": Array(resources), .. } else {
    fail("resources")
  }
  for resource in resources {
    guard resource is Object(r) && r.get("scopeMetrics") is Some(Array(scopes)) else {
      fail("scopes")
    }
    let rh = r.copy()
    ignore(rh.remove("scopeMetrics"))
    if scopes.is_empty() {
      rows.push(Json::array(["empty-resource", Json::object(rh)]).stringify())
    }
    for scope in scopes {
      guard scope is Object(s) && s.get("metrics") is Some(Array(metrics)) else {
        fail("metrics")
      }
      let sh = s.copy()
      ignore(sh.remove("metrics"))
      if metrics.is_empty() {
        rows.push(
          Json::array(["empty-scope", Json::object(rh), Json::object(sh)]).stringify(),
        )
      }
      for metric in metrics {
        guard metric is Object(m) else { fail("metric") }
        for kind in ["sum", "histogram", "exponentialHistogram", "gauge"] {
          if m.get(kind) is Some(Object(body)) &&
            body.get("dataPoints") is Some(Array(points)) {
            let mh = m.copy()
            let bh = body.copy()
            ignore(bh.remove("dataPoints"))
            mh[kind] = Json::object(bh)
            if points.is_empty() {
              rows.push(
                Json::array([
                  "empty-metric",
                  Json::object(rh),
                  Json::object(sh),
                  Json::object(mh),
                ]).stringify(),
              )
            }
            for point in points {
              rows.push(
                Json::array([
                  Json::object(rh),
                  Json::object(sh),
                  Json::object(mh),
                  point,
                ]).stringify(),
              )
            }
          }
        }
      }
    }
  }
  rows
}

///|
test "adjacent compaction preserves every kind all metadata exact integers and traversal order" {
  let input = compact_fixture()
  guard input is { "resourceMetrics": [Object(r)], .. } &&
    r.get("scopeMetrics") is Some(Array([Object(s)])) &&
    s.get("metrics") is Some(Array(metrics)) else {
    fail("fixture")
  }
  let repeated : Array[Json] = []
  for metric in metrics {
    for _ in 0..<3 {
      repeated.push(@metricstitch.parse_input(metric.stringify()))
    }
  }
  s["metrics"] = Json::array(repeated)
  let request : Json = {
    "resourceMetrics": [
      Json::object(r),
      @metricstitch.parse_input(Json::object(r).stringify()),
    ],
  }
  let saved = request.stringify()
  let compact = @metricstitch.compact_otlp(request)
  assert_eq(compact_rows(compact), compact_rows(request))
  assert_eq(compact_rows(compact).length(), 30)
  assert_true(compact.stringify().length() < saved.length())
  assert_eq(
    @metricstitch.compact_otlp(compact).stringify(),
    compact.stringify(),
  )
  assert_eq(
    @metricstitch.compact_otlp(request).stringify(),
    compact.stringify(),
  )
  assert_eq(request.stringify(), saved)
  guard compact
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": Array(result), .. }], .. },
      ],
      ..
    } else {
    fail("compacted groups")
  }
  assert_eq(result.length(), 10) // metric order is never rearranged across others
  assert_true(
    result[0] is { "sum": { "dataPoints": Array(ps), .. }, .. } &&
    ps.length() == 3,
  )
  guard result[0] is Object(first) else { fail("first") }
  first["name"] = Json("changed output")
  assert_eq(request.stringify(), saved)
}

///|
test "adjacent resource scope and metric boundaries collapse without erasing empty barriers" {
  let source = compact_fixture()
  guard source
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": Array(metrics), .. }], .. },
      ],
      ..
    } else {
    fail("fixture")
  }
  let metric = metrics[0]
  let scope : Json = { "metrics": [metric] }
  let resource : Json = { "scopeMetrics": [scope] }
  let empty_resource : Json = { "scopeMetrics": [] }
  let empty_scope : Json = { "metrics": [] }
  guard metric is Object(m) && m.get("sum") is Some(Object(body)) else {
    fail("sum")
  }
  let empty_body = body.copy()
  empty_body["dataPoints"] = Json::array([])
  let empty_m = m.copy()
  empty_m["sum"] = Json::object(empty_body)
  let cases : Array[Json] = [
    { "resourceMetrics": [resource, resource, resource] },
    { "resourceMetrics": [resource, empty_resource, resource] },
    { "resourceMetrics": [{ "scopeMetrics": [scope, empty_scope, scope] }] },
    {
      "resourceMetrics": [
        {
          "scopeMetrics": [
            { "metrics": [metric, Json::object(empty_m), metric] },
          ],
        },
      ],
    },
    { "resourceMetrics": [{ "scopeMetrics": [scope, scope, scope] }] },
  ]
  for input in cases {
    let output = @metricstitch.compact_otlp(input)
    assert_eq(compact_rows(output), compact_rows(input))
    assert_eq(@metricstitch.compact_otlp(output), output)
  }
  assert_true(
    @metricstitch.compact_otlp(cases[0])
    is {
      "resourceMetrics": [
        {
          "scopeMetrics": [
            { "metrics": [{ "sum": { "dataPoints": Array(p), .. }, .. }], .. },
          ],
          ..
        },
      ],
      ..
    } &&
    p.length() == 3,
  )
  assert_true(
    @metricstitch.compact_otlp(cases[1]) is { "resourceMetrics": [_, _, _], .. },
  )
}

///|
test "different metadata absent fields attribute ordering and lexemes are not normalized" {
  guard compact_fixture() is { "resourceMetrics": [source], .. } else {
    fail("fixture")
  }
  guard source is Object(r) else { fail("resource") }
  for
    (key, value) in [
      ("schemaUrl", Json("https://example.com/resource/v2")),
      (
        "resource",
        ({ "attributes": [{ "key": "a", "value": { "intValue": "1" } }] } : Json),
      ),
      (
        "resource",
        (
          {
            "attributes": [
              { "key": "a", "value": { "doubleValue": 1.0 } },
              { "key": "b", "value": { "stringValue": "2" } },
            ],
          } : Json),
      ),
    ] {
    let changed = r.copy()
    changed[key] = value
    let input : Json = {
      "resourceMetrics": [source, Json::object(changed), source],
    }
    assert_eq(@metricstitch.compact_otlp(input), input)
  }
  let minimal : Json = {
    "resourceMetrics": [
      {
        "scopeMetrics": [
          {
            "metrics": [
              {
                "name": "g",
                "gauge": {
                  "dataPoints": [{ "timeUnixNano": "2", "asDouble": 1.0 }],
                },
              },
            ],
          },
        ],
      },
    ],
  }
  let explicit = @metricstitch.parse_input(minimal.stringify())
  guard explicit is { "resourceMetrics": [Object(with_default)], .. } else {
    fail("explicit")
  }
  with_default["resource"] = Json::empty_object()
  guard minimal is { "resourceMetrics": [minimal_resource], .. } else {
    fail("minimal")
  }
  let input : Json = {
    "resourceMetrics": [minimal_resource, Json::object(with_default)],
  }
  assert_eq(@metricstitch.compact_otlp(input), input)
  let reordered = @metricstitch.parse_input(Json::object(r).stringify())
  guard reordered is Object(reordered_r) else { fail("reordered") }
  let a : Json = { "key": "a", "value": { "doubleValue": 1.0 } }
  let b : Json = { "key": "b", "value": { "intValue": "2" } }
  let original_r = r.copy()
  original_r["resource"] = { "attributes": [a, b] }
  reordered_r["resource"] = { "attributes": [b, a] }
  let ordered : Json = {
    "resourceMetrics": [Json::object(original_r), reordered],
  }
  assert_eq(@metricstitch.compact_otlp(ordered), ordered)
  let lexical = @metricstitch.parse_input(
    "{\"resourceMetrics\":[{\"resource\":{\"droppedAttributesCount\":0},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"g\",\"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"2\",\"asInt\":\"1\"}]}}]}]},{\"resource\":{\"droppedAttributesCount\":0.0},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"g\",\"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"3\",\"asInt\":\"2\"}]}}]}]}]}",
  )
  assert_eq(
    compact_rows(@metricstitch.compact_otlp(lexical)),
    compact_rows(lexical),
  )
}

///|
test "unsupported delta unknown fields malformed values and oversized input fail without mutation" {
  let valid = compact_fixture()
  let saved = valid.stringify()
  let unsupported = @metricstitch.parse_input(saved)
  guard unsupported is Object(root) else { fail("root") }
  root["unknown"] = Json(true)
  for
    bad in [
      unsupported,
      request("1", "2", "3"),
      Json(null),
      gauge_request({ "timeUnixNano": "2", "asInt": "1", "flags": 1 }),
      gauge_request({ "timeUnixNano": "2", "asDouble": "NaN" }),
    ] {
    assert_true(
      (Some(@metricstitch.compact_otlp(bad)) catch { _ => None }) is None,
    )
  }
  assert_eq(valid.stringify(), saved)
  let oversized = @metricstitch.parse_input(saved)
  guard oversized
    is {
      "resourceMetrics": [
        { "scopeMetrics": [{ "metrics": Array(ms), .. }], .. },
      ],
      ..
    } &&
    ms[0] is Object(m) else {
    fail("oversized")
  }
  m["description"] = Json(String::from_array(Array::make(4000000, 'x')))
  assert_true(
    (Some(@metricstitch.compact_otlp(oversized)) catch { _ => None }) is None,
  )
  assert_eq(
    compact_rows(@metricstitch.compact_otlp(valid)),
    compact_rows(valid),
  )
}
