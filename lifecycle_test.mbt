///|
test "partition keeps every kind and preserves the exact boundary" {
  let i : @metricstitch.Sample = { series: "i", start: 1L, end: 2L, value: 7L, }
  let d : @metricstitch.DoubleSample = {
    series: "d",
    start: 2L,
    end: 3L,
    value: 1.25,
  }
  let h = { ..hist(3L, 4L), series: "h", }
  let state = @metricstitch.State::new(max_series=3).apply([i]).state.apply_doubles([
        d,
      ],
    ).state.apply_histograms([h]).state
  let saved = state.checkpoint()
  let split = state.partition_before(3L)
  assert_eq(split.archived.apply([i]).duplicates, 1)
  assert_eq(split.retained.apply_doubles([d]).duplicates, 1)
  assert_eq(split.retained.apply_histograms([h]).duplicates, 1)
  assert_eq(
    @metricstitch.State::restore(split.archived.checkpoint()).checkpoint(),
    split.archived.checkpoint(),
  )
  assert_eq(
    @metricstitch.State::restore(split.retained.checkpoint()).checkpoint(),
    split.retained.checkpoint(),
  )
  assert_true(
    split.retained.summary()
    is {
      "series": Number(2.0, ..),
      "available": Number(1.0, ..),
      "oldest_end": String("3"),
      ..
    },
  )
  let resumed = split.archived.apply([{ ..i, start: 2L, end: 5L, value: 2L, }])
  assert_eq(resumed.points[0].value, 9L)
  let fresh = split.retained.apply([{ ..i, start: 4L, end: 5L, value: 2L, }])
  assert_eq(fresh.points[0].value, 2L)
  assert_eq(fresh.points[0].start, 4L)
  assert_eq(state.checkpoint(), saved)
}

///|
test "partition handles empty full and zero cutoff without state loss" {
  let empty = @metricstitch.State::new()
  assert_true(
    empty.summary()
    is { "series": Number(0.0, ..), "oldest_end": Null, "newest_end": Null, .. },
  )
  let state = empty.apply([sample(1L, 2L, 7L)]).state
  assert_eq(
    state.partition_before(2L).retained.checkpoint(),
    state.checkpoint(),
  )
  assert_eq(
    state.partition_before(3L).archived.checkpoint(),
    state.checkpoint(),
  )
  assert_true((Some(state.partition_before(0L)) catch { _ => None }) is None)
  let summary = state.summary()
  guard summary is Object(obj) else { fail("summary") }
  obj["series"] = Json(999)
  assert_true(state.summary() is { "series": Number(1.0, ..), .. })
}
