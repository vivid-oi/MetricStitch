///|
/// Missing half-open interval [start,end) before a queued point. A new stream's
/// unknown origin is never invented. blocks_target refers to the following
/// point's end; arithmetic/profile failures are reported separately.
#derive(Eq)
pub(all) struct PendingGap {
  series : String
  start : Int64
  end : Int64
  next_end : Int64
  blocks_target : Bool
}

///|
pub extend PendingGap with Eq::{equal, not_equal}

///|
pub(all) struct PendingReport {
  watermark : Int64
  target : Int64
  pending : Int32
  ready : Int32
  capacity : Int32
  max_delay_ns : Int64
  oldest_end : Int64?
  newest_end : Int64?
  unanchored : Array[String]
  gaps : Array[PendingGap]
  advance_error : String?
}

///|
/// Diagnose every queued gap and dry-run advance without consuming any point.
/// Results follow deterministic end/series/start queue order. Success predicts
/// only a typed advance with this exact buffer and target, not future arrivals.
///
/// ```mbt check
/// test {
///   let b = @metricstitch.ReorderBuffer::new(
///     @metricstitch.State::new(),
///     watermark=1L,
///     max_delay_ns=10L,
///   )
///   assert_eq(b.pending_report(2L).advance_error, None)
///   assert_eq(b.pending_count(), 0)
/// }
/// ```
pub fn ReorderBuffer::pending_report(
  self : ReorderBuffer,
  target : Int64,
) -> PendingReport raise BufferError {
  if target < self.watermark {
    raise ReorderInvalid("report target must not precede the current watermark")
  }
  let expected : Map[String, Int64] = Map([])
  let unanchored : Array[String] = []
  let gaps : Array[PendingGap] = []
  let mut ready = 0
  for point in self.pending {
    let (series, start, end) = point.identity()
    if end <= target {
      ready += 1
    }
    let previous = match expected.get(series) {
      Some(end) => Some(end)
      None =>
        match self.committed.last_buffered(series) {
          Some(last) => Some(last.identity().2)
          None => {
            unanchored.push(series)
            None
          }
        }
    }
    if previous is Some(previous) && start > previous {
      gaps.push({
        series,
        start: previous,
        end: start,
        next_end: end,
        blocks_target: end <= target,
      })
    }
    expected[series] = end
  }
  let advance_error = try {
    ignore(self.advance(target))
    None
  } catch {
    error => Some((error : Error).to_string())
  }
  {
    watermark: self.watermark,
    target,
    pending: self.pending.length(),
    ready,
    capacity: self.max_pending,
    max_delay_ns: self.max_delay_ns,
    oldest_end: self.pending.get(0).map(p => p.identity().2),
    newest_end: self.pending.last().map(p => p.identity().2),
    unanchored,
    gaps,
    advance_error,
  }
}

///|
pub fn PendingReport::to_json(self : PendingReport) -> Json {
  fn timestamp(value : Int64?) -> Json {
    match value {
      Some(n) => Json(n.to_string())
      None => Json(null)
    }
  }
  {
    "watermark": Json(self.watermark.to_string()),
    "target": Json(self.target.to_string()),
    "pending": Json(self.pending),
    "ready": Json(self.ready),
    "capacity": Json(self.capacity),
    "maxDelayNs": Json(self.max_delay_ns.to_string()),
    "oldestEnd": timestamp(self.oldest_end),
    "newestEnd": timestamp(self.newest_end),
    "unanchored": Json::array(self.unanchored.map(s => Json(s))),
    "gaps": Json::array(
      self.gaps.map(g => {
        "series": Json(g.series),
        "start": Json(g.start.to_string()),
        "end": Json(g.end.to_string()),
        "nextEnd": Json(g.next_end.to_string()),
        "blocksTarget": Json(g.blocks_target),
      }),
    ),
    "canAdvance": Json(self.advance_error is None),
    "advanceError": match self.advance_error {
      Some(e) => Json(e)
      None => Json(null)
    },
  }
}

///|
/// Enrich typed gaps with the following point's original OTLP envelope, so an
/// operator can identify its metric/resource/scope/attributes. Owned results
/// are bounded to the same 4M JSON budget as checkpoints. canAdvance includes
/// adapter envelope/output budget validation, not just the typed accumulator.
pub fn OtlpReorderBuffer::pending_report(
  self : OtlpReorderBuffer,
  target : Int64,
) -> Json raise BufferError {
  let report = self.reorder.pending_report(target).to_json()
  guard report is Object(fields) && fields.get("gaps") is Some(Array(gaps)) else {
    abort("report shape")
  }
  for gap in gaps {
    guard gap is Object(g) &&
      g.get("series") is Some(String(series)) &&
      g.get("nextEnd") is Some(String(end)) else {
      abort("gap shape")
    }
    for entry in self.pending {
      let (key, _, next_end) = entry.point.identity()
      if key == series && next_end.to_string() == end {
        g["nextRequest"] = detached_json(entry.request)
        break
      }
    }
  }
  try {
    ignore(self.advance(target))
    fields["canAdvance"] = Json(true)
    fields["advanceError"] = Json(null)
  } catch {
    error => {
      fields["canAdvance"] = Json(false)
      fields["advanceError"] = Json((error : Error).to_string())
    }
  }
  bounded_reorder_json(report)
}
