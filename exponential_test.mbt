///|
fn exp_sample(start : Int64, end : Int64) -> @metricstitch.ExponentialSample {
  {
    series: "latency",
    start,
    end,
    scale: 2,
    zero_count: 1L,
    zero_threshold: 0.0,
    positive: { offset: -3, counts: [1L, 2L, 3L, 4L], },
    negative: { offset: -2, counts: [2L, 1L], },
    count: 14L,
    sum: None,
    min: Some(-0.8),
    max: Some(1.1),
  }
}

///|
test "exponential alignment floors negative indexes and preserves every count" {
  let first = @metricstitch.State::new().apply_exponentials([exp_sample(1L, 2L)])
  let next : @metricstitch.ExponentialSample = {
    ..exp_sample(2L, 3L),
    scale: 0,
    positive: { offset: -1, counts: [5L, 6L], },
    negative: { offset: -1, counts: [4L], },
    zero_count: 2L,
    count: 17L,
    min: Some(-1.0),
    max: Some(1.5),
  }
  let second = first.state.apply_exponentials([next])
  let p = second.points[0]
  assert_eq(p.scale, 0)
  assert_eq(p.start, 1L)
  assert_eq(p.positive.offset, -1)
  assert_eq(p.positive.counts, [11L, 10L])
  assert_eq(p.negative.offset, -1)
  assert_eq(p.negative.counts, [7L])
  assert_eq(p.zero_count, 3L)
  assert_eq(p.count, 31L)
  assert_eq(p.min, Some(-1.0))
  assert_eq(p.max, Some(1.5))
  let saved = second.state.checkpoint()
  assert_true(saved is { "version": Number(4.0, ..), .. })
  let restored = @metricstitch.State::restore(
    @metricstitch.parse_input(saved.stringify()),
  )
  assert_eq(restored.checkpoint(), saved)
  assert_eq(restored.apply_exponentials([next]).duplicates, 1)
  assert_true(
    first.state.summary()
    is { "series": Number(1.0, ..), "exponential": Number(1.0, ..), .. },
  )
}

///|
test "exponential automatic downscale bounds dense spans with exact populations" {
  let one : @metricstitch.ExponentialSample = {
    ..exp_sample(1L, 2L),
    scale: 10,
    positive: { offset: 0, counts: [1L], },
    negative: { offset: 0, counts: [], },
    zero_count: 0L,
    count: 1L,
    min: None,
    max: None,
  }
  let first = @metricstitch.State::new().apply_exponentials([one])
  let result = first.state.apply_exponentials([
    { ..one, start: 2L, end: 3L, positive: { offset: 4096, counts: [1L], }, },
  ])
  let p = result.points[0]
  assert_eq(p.scale, 7)
  assert_eq(p.positive.counts.length(), 513)
  assert_eq(p.positive.counts[0], 1L)
  assert_eq(p.positive.counts[512], 1L)
  assert_eq(p.count, 2L)
  assert_eq(
    @metricstitch.State::restore(result.state.checkpoint()).checkpoint(),
    result.state.checkpoint(),
  )
  let edge = {
    ..one,
    scale: -10,
    positive: { offset: -2147483648, counts: [1L], },
  }
  let state = @metricstitch.State::new().apply_exponentials([edge]).state
  let finest = {
    ..one,
    scale: 20,
    positive: { offset: -2147483648, counts: [1L], },
  }
  let wide = @metricstitch.State::new().apply_exponentials([finest]).state.apply_exponentials([
      {
        ..one,
        start: 2L,
        end: 3L,
        scale: -10,
        positive: { offset: 0, counts: [1L], },
      },
    ],
  )
  assert_eq(wide.points[0].positive.offset, -2)
  assert_eq(wide.points[0].positive.counts, [1L, 0L, 1L])
  assert_true(
    (Some(
      state.apply_exponentials([
        {
          ..edge,
          start: 2L,
          end: 3L,
          positive: { offset: 2147483647, counts: [1L], },
        },
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "exponential malformed input threshold changes kind limits and overflow are atomic" {
  let empty = @metricstitch.State::new(max_series=1)
  for
    bad in [
      { ..exp_sample(1L, 2L), scale: 21, },
      { ..exp_sample(1L, 2L), scale: -11, },
      {
        ..exp_sample(1L, 2L),
        positive: { offset: 2147483647, counts: [1L, 1L], },
      },
      { ..exp_sample(1L, 2L), count: 1L, },
      { ..exp_sample(1L, 2L), zero_count: -1L, },
      { ..exp_sample(1L, 2L), zero_threshold: -1.0, },
      { ..exp_sample(1L, 2L), sum: Some(10.0), },
      { ..exp_sample(1L, 2L), min: None, },
    ] {
    assert_true(
      (Some(empty.apply_exponentials([bad])) catch { _ => None }) is None,
    )
  }
  let state = empty.apply_exponentials([exp_sample(1L, 2L)]).state
  let saved = state.checkpoint()
  for
    bad in [
      { ..exp_sample(2L, 3L), zero_threshold: 0.1, },
      { ..exp_sample(2L, 3L), series: "other", },
      exp_sample(3L, 4L),
      { ..exp_sample(1L, 2L), min: Some(-1.0), },
    ] {
    assert_true(
      (Some(state.apply_exponentials([bad])) catch { _ => None }) is None,
    )
    assert_eq(state.checkpoint(), saved)
  }
  assert_true(
    (Some(state.apply([{ series: "latency", start: 2L, end: 3L, value: 1L, }])) catch {
      _ => None
    })
    is None,
  )
  let maxed : @metricstitch.ExponentialSample = {
    ..exp_sample(1L, 2L),
    positive: { offset: 0, counts: [], },
    negative: { offset: 0, counts: [], },
    zero_count: 9223372036854775807L,
    count: 9223372036854775807L,
    min: None,
    max: None,
  }
  let full = empty.apply_exponentials([maxed]).state
  assert_true(
    (Some(
      full.apply_exponentials([
        { ..maxed, start: 2L, end: 3L, count: 1L, zero_count: 1L, },
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "exponential arrays lifecycle buffers and checkpoints are detached" {
  let p = exp_sample(2L, 3L)
  let state = @metricstitch.State::new().apply_exponentials([p]).state
  let saved = state.checkpoint()
  p.positive.counts[0] = 99L
  assert_eq(state.checkpoint(), saved)
  assert_eq(state.partition_before(4L).archived.checkpoint(), saved)
  let b = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let held = b.push([Exponential(exp_sample(2L, 3L))], watermark=1L).buffer
  let restored = @metricstitch.ReorderBuffer::restore(held.checkpoint())
  let done = restored.advance(3L)
  assert_eq(done.buffer.state().checkpoint(), saved)
  assert_eq(restored.pending_count(), 1)
  let out = state.apply_exponentials([exp_sample(3L, 4L)])
  let snapshot = out.state.checkpoint()
  out.points[0].negative.counts[0] = 99L
  assert_eq(out.state.checkpoint(), snapshot)
}

///|
test "exponential checkpoint rejects contradictory coarsening and missing populations" {
  let state = @metricstitch.State::new().apply_exponentials([
      exp_sample(1L, 2L),
      exp_sample(2L, 3L),
    ]).state
  let saved = state.checkpoint()
  for
    (old, new) in [
      ("\"count\":\"28\"", "\"count\":\"27\""),
      ("\"scale\":2", "\"scale\":21"),
      ("\"zeroCount\":\"2\"", "\"zeroCount\":\"0\""),
      ("\"version\":4", "\"version\":9"),
    ] {
    let malformed = saved.stringify().replace_all(old~, new~)
    assert_true(malformed != saved.stringify())
    assert_true(
      (Some(@metricstitch.State::restore(@metricstitch.parse_input(malformed))) catch {
        _ => None
      })
      is None,
    )
  }
}
