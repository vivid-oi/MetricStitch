///|
test "disjoint merge round trips an archive with every metric kind" {
  let p : @metricstitch.Sample = {
    series: "integer",
    start: 1L,
    end: 2L,
    value: 7L,
  }
  let d : @metricstitch.DoubleSample = {
    series: "double",
    start: 2L,
    end: 3L,
    value: 0.25,
  }
  let h = hist(3L, 4L)
  let e = { ..exp_sample(4L, 5L), series: "exponential", }
  let state = @metricstitch.State::new(max_series=4).apply([p]).state.apply_doubles([
        d,
      ],
    ).state.apply_histograms([h]).state.apply_exponentials([e]).state
  let before = state.checkpoint().stringify()
  let split = state.partition_before(4L)
  let joined = split.retained.merge_disjoint(
    @metricstitch.State::restore(split.archived.checkpoint()),
  )
  assert_eq(joined.checkpoint().stringify(), before)
  assert_eq(
    split.archived.merge_disjoint(split.retained).checkpoint().stringify(),
    before,
  )
  assert_eq(joined.apply([p]).duplicates, 1)
  assert_eq(joined.apply_doubles([d]).duplicates, 1)
  assert_eq(joined.apply_histograms([h]).duplicates, 1)
  assert_eq(joined.apply_exponentials([e]).duplicates, 1)
  let next = joined.apply([{ ..p, start: 2L, end: 3L, value: 5L, }])
  assert_eq(next.points[0].value, 12L)
  assert_eq(state.checkpoint().stringify(), before)
}

///|
test "merge collisions and destination budgets never change either input" {
  let p : @metricstitch.Sample = {
    series: "same",
    start: 1L,
    end: 2L,
    value: 7L,
  }
  let left = @metricstitch.State::new(max_series=1).apply([p]).state
  let saved = left.checkpoint()
  let different_kind = @metricstitch.State::new().apply_doubles([
      { series: "same", start: 1L, end: 2L, value: 0.5, },
    ]).state
  let independent = @metricstitch.State::new().apply([{ ..p, series: "other", }]).state
  for right in [left, different_kind, independent] {
    let original = right.checkpoint()
    assert_true((Some(left.merge_disjoint(right)) catch { _ => None }) is None)
    assert_eq(left.checkpoint(), saved)
    assert_eq(right.checkpoint(), original)
  }
  let empty = @metricstitch.State::new(max_series=2)
  let joined = empty.merge_disjoint(left).merge_disjoint(independent)
  assert_true(
    joined.summary()
    is { "capacity": Number(2.0, ..), "series": Number(2.0, ..), .. },
  )
  assert_eq(left.merge_disjoint(@metricstitch.State::new()).checkpoint(), saved)
}
