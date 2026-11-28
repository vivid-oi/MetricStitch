///|
fn main raise {
  let first : @metricstitch.Sample = {
    series: "http.requests",
    start: 1L,
    end: 2L,
    value: 5L,
  }
  let saved = @metricstitch.State::new().apply([first]).state.checkpoint()
  let restored = @metricstitch.State::restore(saved)
  assert_eq(restored.apply([first]).duplicates, 1)
  let next = restored.apply([{ ..first, start: 2L, end: 3L, value: 7L, }])
  assert_eq(next.points[0].value, 12L)
  let empty = @metricstitch.State::new()
  assert_eq(
    empty.merge_disjoint(next.state).checkpoint(),
    next.state.checkpoint(),
  )
  let buffer = @metricstitch.ReorderBuffer::new(
    next.state,
    watermark=3L,
    max_delay_ns=10L,
  )
  assert_eq(buffer.pending_report(4L).advance_error, None)
  let stream = @metricstitch.ReplaySession::new(empty).apply_line(
    "{\"resourceMetrics\":[]}",
  )
  assert_eq(@metricstitch.decode_replay_record(stream.receipt()).ordinal, 1L)
  assert_eq(@metricstitch.compact_otlp(stream.request), stream.request)
  println("External module: restored counter = 12; retry suppressed")
  println(
    "External module: archive reattachment, pending diagnostics, replay records and compaction accepted",
  )
}
