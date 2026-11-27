///|
fn delta(
  start : Int64,
  end : Int64,
  value : Int64,
) -> @metricstitch.BufferedPoint {
  // Epoch matches the upstream OTLP example; values are demonstration edits.
  let epoch = 1544712660000000000L
  Counter({
    series: "http.requests",
    start: epoch + start,
    end: epoch + end,
    value,
  })
}

///|
fn main raise {
  let epoch = 1544712660000000000L
  let buffer = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=epoch + 1L,
    max_pending=8,
    max_delay_ns=10L,
  )
  let held = buffer.push([delta(3L, 4L, 3L)], watermark=epoch + 1L).buffer
  let first = held.push([delta(1L, 2L, 5L)], watermark=epoch + 2L)
  let persisted = first.buffer.checkpoint().stringify()
  let restored = @metricstitch.ReorderBuffer::restore(
    @metricstitch.parse_input(persisted),
  )
  let refused = Some(restored.advance(epoch + 4L)) catch {
    @metricstitch.MissingInterval(_) => None
    error => raise error
  }
  assert_true(refused is None)
  let recovered = restored.push([delta(2L, 3L, 7L)], watermark=epoch + 4L)
  assert_eq(recovered.buffer.pending_count(), 0)
  assert_true(recovered.points == [delta(1L, 3L, 12L), delta(1L, 4L, 15L)])
  assert_eq(restored.checkpoint().stringify(), persisted)
  println(
    "Out-of-order 3,1,2: restored pending data; gap refused; cumulative 5,12,15",
  )
}
