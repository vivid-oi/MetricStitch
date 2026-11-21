///|
fn hist(start : Int64, end : Int64) -> @metricstitch.HistogramSample {
  {
    series: "latency",
    start,
    end,
    bounds: [1.0],
    counts: [1L, 1L],
    count: 2L,
    sum: Some(2.0),
    min: Some(0.0),
    max: Some(2.0),
  }
}

///|
test "histogram accumulation checkpoints and arrays are detached" {
  let p = hist(1L, 2L)
  let first = @metricstitch.State::new().apply_histograms([p])
  let saved = first.state.checkpoint()
  assert_true(saved is { "version": Number(3.0, ..), .. })
  p.counts[0] = 999L
  first.points[0].bounds[0] = 999.0
  assert_eq(first.state.checkpoint(), saved)
  let state = @metricstitch.State::restore(
    @metricstitch.parse_input(saved.stringify()),
  )
  assert_eq(state.apply_histograms([hist(1L, 2L)]).duplicates, 1)
  let second = state.apply_histograms([
    { ..hist(2L, 3L), counts: [2L, 0L], sum: Some(1.0), max: Some(1.0), },
  ])
  let result = second.points[0]
  assert_eq(result.counts, [3L, 1L])
  assert_eq(result.count, 4L)
  assert_eq(result.sum, Some(3.0))
  assert_eq(result.min, Some(0.0))
  assert_eq(result.max, Some(2.0))
  assert_eq(result.start, 1L)
  assert_eq(
    @metricstitch.State::restore(second.state.checkpoint()).checkpoint(),
    second.state.checkpoint(),
  )
}

///|
test "histogram malformed buckets and overflow fail transactionally" {
  let initial = @metricstitch.State::new()
  let infinity = 1.0e308 * 2.0
  for
    bad in [
      { ..hist(1L, 2L), counts: [1L], },
      { ..hist(1L, 2L), count: 3L, },
      { ..hist(1L, 2L), bounds: [infinity], },
      { ..hist(1L, 2L), counts: [-1L, 3L], },
      { ..hist(1L, 2L), min: None, },
      { ..hist(1L, 2L), sum: Some(infinity), },
    ] {
    assert_true(
      (Some(initial.apply_histograms([bad])) catch { _ => None }) is None,
    )
  }
  let first = initial.apply_histograms([hist(1L, 2L)]).state
  let saved = first.checkpoint()
  for
    bad in [{ ..hist(2L, 3L), bounds: [2.0], }, { ..hist(2L, 3L), sum: None, }] {
    assert_true(
      (Some(first.apply_histograms([bad])) catch { _ => None }) is None,
    )
  }
  assert_true(
    (Some(first.apply_histograms([hist(2L, 3L), hist(4L, 5L)])) catch {
      _ => None
    })
    is None,
  )
  assert_eq(first.checkpoint(), saved)
  let big : @metricstitch.HistogramSample = {
    ..hist(1L, 2L),
    counts: [9223372036854775807L, 0L],
    count: 9223372036854775807L,
    sum: None,
    min: None,
    max: None,
  }
  let full = initial.apply_histograms([big]).state
  assert_true(
    (Some(
      full.apply_histograms([
        { ..big, start: 2L, end: 3L, counts: [1L, 0L], count: 1L, },
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "histogram zero populations retain extrema and kind budget is shared" {
  let zero : @metricstitch.HistogramSample = {
    ..hist(1L, 2L),
    counts: [0L, 0L],
    count: 0L,
    sum: Some(0.0),
    min: None,
    max: None,
  }
  let state = @metricstitch.State::new(max_series=1).apply_histograms([zero]).state
  let next = state.apply_histograms([hist(2L, 3L)])
  assert_eq(next.points[0].min, Some(0.0))
  let empty_after = next.state.apply_histograms([
    { ..zero, start: 3L, end: 4L, },
  ])
  assert_eq(empty_after.points[0].count, 2L)
  assert_eq(empty_after.points[0].max, Some(2.0))
  assert_eq(
    @metricstitch.State::restore(empty_after.state.checkpoint()).checkpoint(),
    empty_after.state.checkpoint(),
  )
  let other : @metricstitch.Sample = {
    series: "other",
    start: 1L,
    end: 2L,
    value: 1L,
  }
  assert_true((Some(state.apply([other])) catch { _ => None }) is None)
  assert_true(
    (Some(state.apply([{ ..other, series: "latency", }])) catch { _ => None })
    is None,
  )
}

///|
fn histogram_request(start : String, end : String) -> Json {
  {
    "resourceMetrics": [
      {
        "scopeMetrics": [
          {
            "metrics": [
              {
                "name": "latency",
                "histogram": {
                  "aggregationTemporality": 1,
                  "dataPoints": [
                    {
                      "startTimeUnixNano": Json(start),
                      "timeUnixNano": Json(end),
                      "explicitBounds": [1],
                      "bucketCounts": ["1", "1"],
                      "count": "2",
                      "sum": 2,
                      "min": 0,
                      "max": 2,
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
test "OTLP histograms carry cumulative buckets and survive serialized state" {
  let state = @metricstitch.State::new()
  let input = histogram_request("1", "2")
  let saved = input.stringify()
  let first = @metricstitch.process_otlp(state, input)
  let second = @metricstitch.process_otlp(
    @metricstitch.State::restore(
      @metricstitch.parse_input(first.state.checkpoint().stringify()),
    ),
    histogram_request("2", "3"),
  )
  let output = second.request.stringify()
  assert_true(output.contains("\"count\":\"4\""))
  assert_true(output.contains("\"bucketCounts\":[\"2\",\"2\"]"))
  assert_true(output.contains("\"aggregationTemporality\":2"))
  assert_eq(input.stringify(), saved)
}
