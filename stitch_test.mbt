///|
fn sample(start : Int64, end : Int64, value : Int64) -> @metricstitch.Sample {
  { series: "requests", start, end, value, }
}

///|
test "continuity replay and atomic failure" {
  let initial = @metricstitch.State::new()
  let first = initial.apply([sample(1L, 2L, 7L)])
  let second = first.state.apply([sample(2L, 3L, 5L)])
  assert_true(second.points[0] == sample(1L, 3L, 12L))
  assert_eq(second.state.apply([sample(2L, 3L, 5L)]).duplicates, 1)
  for
    bad in [
      sample(2L, 3L, 6L),
      sample(4L, 5L, 2L),
      sample(0L, 2L, 1L),
      sample(3L, 4L, -1L),
    ] {
    assert_true((Some(second.state.apply([bad])) catch { _ => None }) is None)
  }
  assert_true(
    (Some(first.state.apply([sample(2L, 3L, 5L), sample(4L, 5L, 1L)])) catch {
      _ => None
    })
    is None,
  )
  assert_true(first.state.apply([sample(2L, 3L, 5L)]).points == second.points)
  assert_eq(initial.apply([sample(1L, 2L, 1L)]).points[0].value, 1L)
}

///|
test "overflow budgets and zero delta" {
  let max = @metricstitch.State::new().apply([
    sample(1L, 2L, 9223372036854775807L),
  ])
  assert_true(
    (Some(max.state.apply([sample(2L, 3L, 1L)])) catch { _ => None }) is None,
  )
  assert_eq(
    max.state.apply([sample(2L, 3L, 0L)]).points[0].value,
    9223372036854775807L,
  )
  let limited = @metricstitch.State::new(max_series=1).apply([
    sample(1L, 2L, 0L),
  ])
  let other : @metricstitch.Sample = {
    series: "other",
    start: 1L,
    end: 2L,
    value: 1L,
  }
  assert_true((Some(limited.state.apply([other])) catch { _ => None }) is None)
  assert_true(
    (Some(@metricstitch.State::new(max_series=0)) catch { _ => None }) is None,
  )
}
