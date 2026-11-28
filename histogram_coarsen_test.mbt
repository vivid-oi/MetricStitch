///|
fn fine_hist(start : Int64, end : Int64) -> @metricstitch.HistogramSample {
  {
    series: "latency",
    start,
    end,
    bounds: [1.0, 2.0, 4.0],
    counts: [1L, 2L, 3L, 4L],
    count: 10L,
    sum: Some(20.0),
    min: Some(0.0),
    max: Some(5.0),
  }
}

///|
test "explicit coarsening conserves counts statistics and composed layouts" {
  let p = fine_hist(1L, 2L)
  let coarse = p.coarsen([2.0])
  assert_eq(coarse.counts, [3L, 7L])
  assert_eq(coarse.count, p.count)
  assert_eq(coarse.sum, p.sum)
  assert_eq(coarse.min, p.min)
  assert_eq(coarse.max, p.max)
  assert_eq(p.coarsen([1.0, 2.0]).coarsen([2.0]).counts, coarse.counts)
  assert_eq(coarse.coarsen([]).counts, [10L])
  assert_true(p.coarsen(p.bounds) == p)
  coarse.counts[0] = 99L
  coarse.bounds[0] = 99.0
  assert_eq(p.counts, [1L, 2L, 3L, 4L])
}

///|
test "coarsening rejects invented unsorted nonfinite and malformed inputs" {
  let p = fine_hist(1L, 2L)
  for bounds in [[1.5], [2.0, 1.0], [1.0, 1.0], [1.0e308 * 2.0]] {
    assert_true((Some(p.coarsen(bounds)) catch { _ => None }) is None)
  }
  assert_true(
    (Some({ ..p, count: 11L, }.coarsen([])) catch { _ => None }) is None,
  )
  let maxed = {
    ..p,
    bounds: [1.0],
    counts: [9223372036854775807L, 0L],
    count: 9223372036854775807L,
    sum: None,
    min: None,
    max: None,
  }
  assert_eq(maxed.coarsen([]).counts, [9223372036854775807L])
}

///|
test "coarsening state migrates totals and retries without resetting origin" {
  let p = fine_hist(1L, 2L)
  let original = @metricstitch.State::new().apply_histograms([p]).state
  let saved = original.checkpoint()
  let migrated = original.coarsen_histogram("latency", [2.0])
  let resumed = @metricstitch.State::restore(migrated.checkpoint())
  assert_eq(resumed.apply_histograms([p.coarsen([2.0])]).duplicates, 1)
  let next = { ..fine_hist(2L, 3L), bounds: [0.0, 2.0, 4.0], }.coarsen([2.0])
  let result = resumed.apply_histograms([next])
  assert_eq(result.points[0].counts, [6L, 14L])
  assert_eq(result.points[0].start, 1L)
  assert_eq(result.points[0].count, 20L)
  assert_eq(original.checkpoint(), saved)
  assert_true(
    (Some(original.coarsen_histogram("missing", [])) catch { _ => None })
    is None,
  )
}

///|
test "OTLP coarsening preserves all other data and fails atomically" {
  let input = histogram_request("1", "2")
  let before = input.stringify()
  let coarse = @metricstitch.coarsen_otlp_histograms(input, [])
  assert_true(coarse.stringify().contains("\"bucketCounts\":[\"2\"]"))
  assert_true(coarse.stringify().contains("\"aggregationTemporality\":1"))
  assert_eq(input.stringify(), before)
  assert_eq(
    @metricstitch.coarsen_otlp_histograms(request("1", "2", "7"), []),
    request("1", "2", "7"),
  )
  assert_true(
    (Some(@metricstitch.coarsen_otlp_histograms(input, [2.0])) catch {
      _ => None
    })
    is None,
  )
  assert_eq(input.stringify(), before)
}
