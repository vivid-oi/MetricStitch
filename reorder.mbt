///|
/// Input points are deltas; emitted points carry cumulative origins and values.
#derive(Eq)
pub(all) enum BufferedPoint {
  Counter(Sample)
  DoubleCounter(DoubleSample)
  Histogram(HistogramSample)
}

///|
pub extend BufferedPoint with Eq::{equal, not_equal}

///|
pub suberror BufferError {
  ReorderInvalid(String)
  LatePoint(String)
  BufferFull
  WindowExceeded(String)
  ReorderConflict(String)
  MissingInterval(String)
}

///|
/// Explicit event-time watermark; no wall clock, timer, eviction or data loss.
pub struct ReorderBuffer {
  priv committed : State
  priv pending : Array[BufferedPoint]
  priv watermark : Int64
  priv max_pending : Int32
  priv max_delay_ns : Int64
}

///|
pub(all) struct ReorderStep {
  buffer : ReorderBuffer
  points : Array[BufferedPoint]
  duplicates : Int32
}

///|
/// watermark is the closed event-time boundary; later arrivals ending at or
/// before it are refused except exact last-point retries. max_delay_ns bounds
/// how far pending ends may lie ahead of the watermark, not processing latency.
///
/// ```mbt check
/// test {
///   let b = @metricstitch.ReorderBuffer::new(
///     @metricstitch.State::new(),
///     watermark=1L,
///     max_delay_ns=10L,
///   )
///   assert_eq(b.advance(2L).buffer.pending_count(), 0)
/// }
/// ```
pub fn ReorderBuffer::new(
  state : State,
  watermark~ : Int64,
  max_pending~ : Int32 = 128,
  max_delay_ns~ : Int64,
) -> ReorderBuffer raise BufferError {
  if watermark <= 0L ||
    max_pending <= 0 ||
    max_pending > 4096 ||
    max_delay_ns <= 0L {
    raise ReorderInvalid(
      "positive watermark/delay and max_pending in 1..4096 required",
    )
  }
  for r in state.records {
    if r.last.end > watermark {
      raise ReorderInvalid("watermark precedes committed state")
    }
  }
  for r in state.doubles {
    if r.last.end > watermark {
      raise ReorderInvalid("watermark precedes committed state")
    }
  }
  for r in state.histograms {
    if r.last_hist.end > watermark {
      raise ReorderInvalid("watermark precedes committed state")
    }
  }
  { committed: state, pending: [], watermark, max_pending, max_delay_ns, }
}

///|
pub fn ReorderBuffer::state(self : ReorderBuffer) -> State {
  self.committed
}

///|
pub fn ReorderBuffer::pending_count(self : ReorderBuffer) -> Int32 {
  self.pending.length()
}

///|
fn BufferedPoint::identity(self : BufferedPoint) -> (String, Int64, Int64) {
  match self {
    Counter(p) => (p.series, p.start, p.end)
    DoubleCounter(p) => (p.series, p.start, p.end)
    Histogram(p) => (p.series, p.start, p.end)
  }
}

///|
fn BufferedPoint::detached(self : BufferedPoint) -> BufferedPoint {
  match self {
    Histogram(p) => Histogram(copy_histogram(p))
    _ => self
  }
}

///|
fn BufferedPoint::validate(self : BufferedPoint) -> Unit raise StitchError {
  match self {
    Counter(p) => ignore(State::new().apply([p]))
    DoubleCounter(p) => ignore(State::new().apply_doubles([p]))
    Histogram(p) => validate_histogram(p)
  }
}

///|
fn BufferedPoint::same_profile(
  self : BufferedPoint,
  other : BufferedPoint,
) -> Bool {
  match (self, other) {
    (Counter(_), Counter(_)) | (DoubleCounter(_), DoubleCounter(_)) => true
    (Histogram(a), Histogram(b)) =>
      a.bounds == b.bounds &&
      (a.sum is Some(_)) == (b.sum is Some(_)) &&
      (
        a.count == 0L ||
        b.count == 0L ||
        (a.min is Some(_)) == (b.min is Some(_))
      )
    _ => false
  }
}

///|
fn State::last_buffered(self : State, series : String) -> BufferedPoint? {
  match self.index.get(series) {
    Some(IntSlot(i)) => Some(Counter(self.records[i].last))
    Some(DoubleSlot(i)) => Some(DoubleCounter(self.doubles[i].last))
    Some(HistogramSlot(i)) => Some(Histogram(self.histograms[i].last_hist))
    None => None
  }
}

///|
/// Stage at most 4096 points and advance a nondecreasing watermark atomically.
/// Ready points are ordered by end, series, start. Missing predecessors reject
/// the whole call, leaving the old buffer available for correction and retry.
/// A new stream begins at its earliest emitted interval; callers must establish
/// its intended start by supplying all predecessors before advancing watermark.
pub fn ReorderBuffer::push(
  self : ReorderBuffer,
  batch : Array[BufferedPoint],
  watermark~ : Int64,
) -> ReorderStep raise BufferError {
  if watermark < self.watermark || batch.length() > 4096 {
    raise ReorderInvalid("watermark must not decrease; batch limit is 4096")
  }
  let pending = self.pending.copy()
  let mut duplicates = 0
  for supplied in batch {
    supplied.validate() catch {
      Invalid(message) => raise ReorderInvalid(message)
    }
    let p = supplied.detached()
    let (series, start, end) = p.identity()
    if self.committed.last_buffered(series) is Some(last) {
      if p == last {
        duplicates += 1
        continue
      }
      let (_, old_start, old_end) = last.identity()
      if !p.same_profile(last) || start < old_end {
        raise ReorderConflict(
          series +
          ": changed kind/layout or overlaps committed interval " +
          old_start.to_string(),
        )
      }
    }
    let mut duplicate = false
    for old in pending {
      let (old_series, old_start, old_end) = old.identity()
      if old_series != series {
        continue
      }
      if p == old {
        duplicate = true
        break
      }
      if !p.same_profile(old) || (start < old_end && old_start < end) {
        raise ReorderConflict(series + ": conflicting buffered point")
      }
    }
    if duplicate {
      duplicates += 1
      continue
    }
    if end <= self.watermark {
      raise LatePoint(series)
    }
    pending.push(p)
  }
  pending.sort_by((a, b) => {
    let (ak, ast, ae) = a.identity()
    let (bk, bst, be) = b.identity()
    let c = ae.compare(be)
    if c != 0 {
      c
    } else {
      let c = ak.compare(bk)
      if c != 0 {
        c
      } else {
        ast.compare(bst)
      }
    }
  })
  let mut current = self.committed.detached()
  let retained : Array[BufferedPoint] = []
  let output : Array[BufferedPoint] = []
  for point in pending {
    let (series, _, end) = point.identity()
    if end > watermark {
      if end - watermark > self.max_delay_ns {
        raise WindowExceeded(series)
      }
      retained.push(point)
      continue
    }
    let issue = Ref(InvalidInput)
    match point {
      Counter(p) => {
        let step = current.apply_int_impl([p], issue, writable=true) catch {
          Invalid(message) =>
            if issue.val == NoncontiguousInterval {
              raise MissingInterval(series)
            } else {
              raise ReorderInvalid(message)
            }
        }
        current = step.state
        duplicates += step.duplicates
        for p in step.points {
          output.push(Counter(p))
        }
      }
      DoubleCounter(p) => {
        let step = current.apply_double_impl([p], issue, writable=true) catch {
          Invalid(message) =>
            if issue.val == NoncontiguousInterval {
              raise MissingInterval(series)
            } else {
              raise ReorderInvalid(message)
            }
        }
        current = step.state
        duplicates += step.duplicates
        for p in step.points {
          output.push(DoubleCounter(p))
        }
      }
      Histogram(p) => {
        let step = current.apply_histogram_impl([p], issue, writable=true) catch {
          Invalid(message) =>
            if issue.val == NoncontiguousInterval {
              raise MissingInterval(series)
            } else {
              raise ReorderInvalid(message)
            }
        }
        current = step.state
        duplicates += step.duplicates
        for p in step.points {
          output.push(Histogram(p))
        }
      }
    }
  }
  if retained.length() > self.max_pending {
    raise BufferFull
  }
  {
    buffer: { ..self, committed: current, pending: retained, watermark, },
    points: output,
    duplicates,
  }
}

///|
/// Advance without adding points. Failure never evicts a buffered interval.
pub fn ReorderBuffer::advance(
  self : ReorderBuffer,
  watermark : Int64,
) -> ReorderStep raise BufferError {
  self.push([], watermark~)
}
