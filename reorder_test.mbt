///|
fn bp(start : Int64, end : Int64, value : Int64) -> @metricstitch.BufferedPoint {
  Counter({ series: "requests", start, end, value, })
}

///|
test "bounded reordering restores pending deltas and recovers from a missing interval" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let third = base.push([bp(3L, 4L, 3L)], watermark=1L).buffer
  let first = third.push([bp(1L, 2L, 5L)], watermark=2L)
  assert_true(first.points == [bp(1L, 2L, 5L)])
  let saved = first.buffer.checkpoint().stringify()
  let restored = @metricstitch.ReorderBuffer::restore(
    @metricstitch.parse_input(saved),
  )
  assert_eq(restored.checkpoint().stringify(), saved)
  assert_eq(restored.pending_count(), 1)
  let missing = Some(restored.advance(4L)) catch {
    @metricstitch.MissingInterval(series) => {
      assert_eq(series, "requests")
      None
    }
    error => raise error
  }
  assert_true(missing is None)
  let done = restored.push([bp(2L, 3L, 7L)], watermark=4L)
  assert_true(done.points == [bp(1L, 3L, 12L), bp(1L, 4L, 15L)])
  assert_eq(restored.checkpoint().stringify(), saved)
}

///|
test "shuffled contiguous points are equivalent to ordered cumulative processing" {
  let ordered = Array::makei(64, i => {
    bp(i.to_int64() + 1L, i.to_int64() + 2L, i.to_int64())
  })
  let shuffled = Array::makei(64, i => ordered[i * 17 % 64])
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=128L,
  )
  let held = base.push(shuffled, watermark=1L).buffer
  assert_eq(held.pending_count(), 64)
  assert_eq(held.push(shuffled, watermark=1L).duplicates, 64)
  let done = held.advance(65L)
  let expected = base.push(ordered, watermark=65L)
  assert_true(done.points == expected.points)
  assert_eq(done.buffer.checkpoint(), expected.buffer.checkpoint())
  assert_true(done.points.last() == Some(bp(1L, 65L, 2016L)))
  assert_eq(done.buffer.push([ordered[63]], watermark=65L).duplicates, 1)
  assert_true(
    (Some(done.buffer.push([ordered[0]], watermark=65L)) catch { _ => None })
    is None,
  )
  assert_eq(held.pending_count(), 64)
}

///|
test "buffer limits conflicts lateness and failed watermark updates preserve input" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_pending=1,
    max_delay_ns=10L,
  )
  let held = base.push([bp(3L, 4L, 3L)], watermark=1L).buffer
  let saved = held.checkpoint()
  for
    (batch, watermark) in [
      ([bp(4L, 5L, 1L)], 1L),
      ([bp(3L, 4L, 4L)], 1L),
      ([bp(2L, 4L, 3L)], 1L),
      ([bp(11L, 12L, 1L)], 1L),
      ([], 0L),
      ([bp(0L, 1L, 1L)], 1L),
    ] {
    assert_true(
      (Some(held.push(batch, watermark~)) catch { _ => None }) is None,
    )
    assert_eq(held.checkpoint(), saved)
  }
  let late = base.advance(3L).buffer
  let rejected = Some(late.push([bp(1L, 2L, 1L)], watermark=3L)) catch {
    @metricstitch.LatePoint(_) => None
    error => raise error
  }
  assert_true(rejected is None)
  let recovered = held.push([bp(1L, 3L, 5L)], watermark=4L)
  assert_true(recovered.points == [bp(1L, 3L, 5L), bp(1L, 4L, 8L)])
}

///|
test "mixed buffered kinds preserve histogram ownership across checkpoint and output" {
  let h = hist(2L, 3L)
  let d : @metricstitch.DoubleSample = {
    series: "seconds",
    start: 2L,
    end: 3L,
    value: 1.25,
  }
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let held = base.push(
      [Histogram(h), DoubleCounter(d), bp(2L, 3L, 7L)],
      watermark=1L,
    ).buffer
  let saved = held.checkpoint()
  h.counts[0] = 99L
  assert_eq(held.checkpoint(), saved)
  let restored = @metricstitch.ReorderBuffer::restore(
    @metricstitch.parse_input(saved.stringify()),
  )
  let done = restored.advance(3L)
  assert_eq(done.points.length(), 3)
  let snapshot = done.buffer.checkpoint()
  for p in done.points {
    if p is Histogram(h) {
      h.counts[0] = 88L
    }
  }
  assert_eq(done.buffer.checkpoint(), snapshot)
  assert_eq(restored.checkpoint(), saved)
  let conflict = Some(
    held.push([DoubleCounter({ ..d, series: "requests", })], watermark=1L),
  ) catch {
    @metricstitch.ReorderConflict(_) => None
    error => raise error
  }
  assert_true(conflict is None)
}

///|
test "buffer checkpoint rejects malformed unknown duplicate and out-of-window data" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let checkpoint = base.push([bp(2L, 3L, 5L)], watermark=1L).buffer.checkpoint()
  guard checkpoint is Object(fields) &&
    fields.get("pending") is Some(Array([p])) else {
    fail("checkpoint")
  }
  for
    changed in [
      ("version", Json(2)),
      ("extra", Json(true)),
      ("max_pending", Json("0")),
      ("max_delay_ns", Json("1")),
      ("watermark", Json("3")),
      ("pending", Json::array([p, p])),
    ] {
    let copy = fields.copy()
    copy[changed.0] = changed.1
    assert_true(
      (Some(@metricstitch.ReorderBuffer::restore(Json::object(copy))) catch {
        _ => None
      })
      is None,
    )
  }
}

///|
test "buffer horizon capacity and timestamp endpoints are exact" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_pending=1,
    max_delay_ns=10L,
  )
  let exact = base.push([bp(10L, 11L, 1L)], watermark=1L)
  assert_eq(exact.buffer.pending_count(), 1)
  let window = Some(base.push([bp(11L, 12L, 1L)], watermark=1L)) catch {
    @metricstitch.WindowExceeded(_) => None
    error => raise error
  }
  assert_true(window is None)
  let full = Some(exact.buffer.push([bp(9L, 10L, 1L)], watermark=1L)) catch {
    @metricstitch.BufferFull => None
    error => raise error
  }
  assert_true(full is None)
  let drained = base.push([bp(1L, 2L, 1L), bp(2L, 3L, 2L)], watermark=2L)
  assert_eq(drained.buffer.pending_count(), 1)
  let edge = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=9223372036854775805L,
    max_delay_ns=2L,
  )
  let held = edge.push(
    [bp(9223372036854775806L, 9223372036854775807L, 1L)],
    watermark=9223372036854775805L,
  )
  assert_eq(held.buffer.advance(9223372036854775807L).points.length(), 1)
}

///|
test "buffer rejects cumulative overflow for every kind without consuming deltas" {
  let h : @metricstitch.HistogramSample = {
    series: "h",
    start: 1L,
    end: 2L,
    bounds: [],
    counts: [9223372036854775807L],
    count: 9223372036854775807L,
    sum: None,
    min: None,
    max: None,
  }
  let d : @metricstitch.DoubleSample = {
    series: "d",
    start: 1L,
    end: 2L,
    value: 1.0e308,
  }
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  for
    (first, next) in [
      (bp(1L, 2L, 9223372036854775807L), bp(2L, 3L, 1L)),
      (DoubleCounter(d), DoubleCounter({ ..d, start: 2L, end: 3L, })),
      (
        Histogram(h),
        Histogram({ ..h, start: 2L, end: 3L, counts: [1L], count: 1L, }),
      ),
    ] {
    let committed = base.push([first], watermark=2L).buffer
    let saved = committed.checkpoint()
    let failed = Some(committed.push([next], watermark=3L)) catch {
      @metricstitch.ReorderInvalid(_) => None
      error => raise error
    }
    assert_true(failed is None)
    assert_eq(committed.checkpoint(), saved)
    assert_eq(committed.push([first], watermark=2L).duplicates, 1)
  }
}
