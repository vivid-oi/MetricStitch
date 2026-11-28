///|
test "report enumerates all interleaved gaps and dry run never consumes" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=20L,
  )
  let committed = base.push([bp(1L, 2L, 5L)], watermark=2L).buffer
  let other : @metricstitch.BufferedPoint = DoubleCounter({
    series: "seconds",
    start: 4L,
    end: 5L,
    value: 0.5,
  })
  let held = committed.push(
      [
        bp(7L, 8L, 1L),
        other,
        bp(3L, 4L, 2L),
        DoubleCounter({ series: "seconds", start: 8L, end: 9L, value: 1.0, }),
      ],
      watermark=2L,
    ).buffer
  let saved = held.checkpoint().stringify()
  let report = held.pending_report(5L)
  assert_eq(report.pending, 4)
  assert_eq(report.ready, 2)
  assert_eq(report.oldest_end, Some(4L))
  assert_eq(report.newest_end, Some(9L))
  assert_eq(report.unanchored, ["seconds"])
  assert_eq(report.gaps.length(), 3)
  assert_true(
    report.gaps[0] ==
    {
      series: "requests",
      start: 2L,
      end: 3L,
      next_end: 4L,
      blocks_target: true,
    },
  )
  assert_true(
    report.gaps[1] ==
    {
      series: "requests",
      start: 4L,
      end: 7L,
      next_end: 8L,
      blocks_target: false,
    },
  )
  assert_true(
    report.gaps[2] ==
    {
      series: "seconds",
      start: 5L,
      end: 8L,
      next_end: 9L,
      blocks_target: false,
    },
  )
  assert_true(report.advance_error is Some(_))
  assert_true(held.pending_report(3L).advance_error is None)
  assert_eq(held.pending_report(5L).to_json(), report.to_json())
  assert_true((Some(held.pending_report(1L)) catch { _ => None }) is None)
  assert_eq(held.checkpoint().stringify(), saved)
  let fixed = held.push(
      [
        bp(2L, 3L, 1L),
        bp(4L, 7L, 1L),
        DoubleCounter({ series: "seconds", start: 5L, end: 8L, value: 0.5, }),
      ],
      watermark=2L,
    ).buffer
  assert_eq(fixed.pending_report(9L).gaps.length(), 0)
  assert_true(fixed.pending_report(9L).advance_error is None)
  assert_eq(fixed.advance(9L).buffer.pending_count(), 0)
}

///|
test "no gaps does not promise arithmetic success or infer an unknown origin" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let held = base.push(
      [bp(3L, 4L, 9223372036854775807L), bp(4L, 5L, 1L)],
      watermark=1L,
    ).buffer
  let report = held.pending_report(5L)
  assert_eq(report.unanchored, ["requests"])
  assert_eq(report.gaps.length(), 0)
  assert_true(report.advance_error is Some(_))
  let report = held.pending_report(4L)
  assert_true(report.advance_error is None)
  let empty = base.pending_report(9223372036854775807L)
  assert_eq(empty.oldest_end, None)
  assert_eq(empty.newest_end, None)
  assert_true(empty.advance_error is None)
}

///|
test "histogram and exponential reports use their committed end boundaries" {
  let base = @metricstitch.ReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let first = base.push(
      [
        Histogram(hist(1L, 2L)),
        Exponential({ ..exp_sample(1L, 2L), series: "exponential", }),
      ],
      watermark=2L,
    ).buffer
  let held = first.push(
      [
        Histogram(hist(4L, 5L)),
        Exponential({ ..exp_sample(3L, 4L), series: "exponential", }),
      ],
      watermark=2L,
    ).buffer
  let report = held.pending_report(5L)
  assert_eq(report.gaps.length(), 2)
  assert_true(report.gaps.iter().all(g => g.start == 2L && g.blocks_target))
  assert_eq(report.unanchored.length(), 0)
}

///|
test "OTLP report includes detached re-fetch context and preserves receipts" {
  let base = @metricstitch.OtlpReorderBuffer::new(
    @metricstitch.State::new(),
    watermark=1L,
    max_delay_ns=10L,
  )
  let first = base.push(request("1", "2", "5"), watermark=2L)
  let held = first.buffer.push(request("3", "4", "3"), watermark=2L).buffer
  let saved = held.checkpoint().stringify()
  let report = held.pending_report(4L)
  guard report is { "canAdvance": False, "gaps": [Object(g)], .. } else {
    fail("report")
  }
  assert_true(
    g.get("nextRequest")
    is Some(
      {
        "resourceMetrics": [
          {
            "scopeMetrics": [
              { "metrics": [{ "name": String("requests"), .. }], .. },
            ],
            ..
          },
        ],
        ..
      }
    ),
  )
  g["nextRequest"] = Json(null)
  assert_eq(held.checkpoint().stringify(), saved)
  assert_true(held.pending_report(2L) is { "canAdvance": True, .. })
  assert_true(
    held.push(request("2", "3", "7"), watermark=4L).buffer.pending_report(4L)
    is { "canAdvance": True, "gaps": [], .. },
  )
}
