///|
fn buffered_json(point : BufferedPoint) -> Json {
  match point {
    Counter(p) =>
      {
        "kind": "int64",
        "series": Json(p.series),
        "start": Json(p.start.to_string()),
        "end": Json(p.end.to_string()),
        "value": Json(p.value.to_string()),
      }
    DoubleCounter(p) =>
      {
        "kind": "double",
        "series": Json(p.series),
        "start": Json(p.start.to_string()),
        "end": Json(p.end.to_string()),
        "value": Json(p.value),
      }
    Histogram(p) => { "kind": "histogram", "point": histogram_json(p) }
  }
}

///|
/// Detached, versioned JSON including committed state and every pending delta.
pub fn ReorderBuffer::checkpoint(self : ReorderBuffer) -> Json {
  {
    "version": 1,
    "state": self.committed.checkpoint(),
    "watermark": Json(self.watermark.to_string()),
    "max_pending": Json(self.max_pending.to_string()),
    "max_delay_ns": Json(self.max_delay_ns.to_string()),
    "pending": Json::array(self.pending.map(buffered_json)),
  }
}

///|
fn read_buffered(value : Json) -> BufferedPoint raise StitchError {
  let obj = fields(
    value,
    ["kind", "series", "start", "end", "value", "point"],
    "buffered point",
  )
  let kind = text(required(obj, "kind"), "kind")
  if kind == "histogram" {
    ignore(fields(value, ["kind", "point"], "histogram envelope"))
    return Histogram(checkpoint_histogram(required(obj, "point")))
  }
  ignore(
    fields(
      value,
      ["kind", "series", "start", "end", "value"],
      "counter envelope",
    ),
  )
  let series = text(required(obj, "series"), "series")
  let start = decimal(required(obj, "start"), "start")
  let end = decimal(required(obj, "end"), "end")
  match kind {
    "int64" =>
      Counter({
        series,
        start,
        end,
        value: decimal(required(obj, "value"), "value"),
      })
    "double" =>
      DoubleCounter({
        series,
        start,
        end,
        value: finite_nonnegative(required(obj, "value")),
      })
    _ => raise Invalid("unsupported buffered kind")
  }
}

///|
/// Validate all state, limits, windows and pending conflicts. No unknown fields,
/// versions, duplicate pending points or silent normalization of state accepted.
pub fn ReorderBuffer::restore(value : Json) -> ReorderBuffer raise BufferError {
  let (state, watermark, limit, delay, points) = try {
    let obj = fields(
      value,
      [
        "version", "state", "watermark", "max_pending", "max_delay_ns", "pending",
      ],
      "buffer checkpoint",
    )
    if required(obj, "version") != Json(1) {
      raise Invalid("unsupported buffer checkpoint version")
    }
    let limit = decimal(required(obj, "max_pending"), "max_pending")
    if limit > 4096L {
      raise Invalid("max_pending exceeds 4096")
    }
    let pending = array(required(obj, "pending"), "pending")
    if pending.length() > limit.to_int() {
      raise Invalid("pending exceeds checkpoint capacity")
    }
    (
      State::restore(required(obj, "state")),
      decimal(required(obj, "watermark"), "watermark"),
      limit.to_int(),
      decimal(required(obj, "max_delay_ns"), "max_delay_ns"),
      pending.map(read_buffered),
    )
  } catch {
    Invalid(message) => raise ReorderInvalid(message)
  }
  let step = ReorderBuffer::new(
    state,
    watermark~,
    max_pending=limit,
    max_delay_ns=delay,
  ).push(points, watermark~)
  if step.duplicates != 0 || !step.points.is_empty() {
    raise ReorderInvalid(
      "checkpoint contains committed or duplicate pending points",
    )
  }
  step.buffer
}
