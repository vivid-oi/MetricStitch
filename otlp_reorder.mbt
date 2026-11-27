///|
/// Owns pending typed deltas together with complete validated OTLP envelopes.
pub struct OtlpReorderBuffer {
  priv reorder : ReorderBuffer
  priv pending : Array[QueuedOtlp]
}

///|
pub(all) struct OtlpReorderStep {
  buffer : OtlpReorderBuffer
  request : Json
  duplicates : Int32
}

///|
fn bounded_reorder_json(value : Json) -> Json raise BufferError {
  parse_input(value.stringify()) catch {
    Invalid(message) => raise ReorderInvalid(message)
  }
}

///|
fn detached_json(value : Json) -> Json {
  match value {
    Array(items) => Json::array(items.map(detached_json))
    Object(fields) => {
      let copy : Map[String, Json] = Map([])
      for key, item in fields {
        copy[key] = detached_json(item)
      }
      Json::object(copy)
    }
    _ => value
  }
}

///|
/// Create an OTLP adapter with the same explicit event-time contract as
/// ReorderBuffer. Requests and recoverable checkpoints are bounded to 4M JSON
/// code units. Existing strict process_otlp behavior remains unchanged.
///
/// ```mbt check
/// test {
///   let b = @metricstitch.OtlpReorderBuffer::new(
///     @metricstitch.State::new(),
///     watermark=1L,
///     max_delay_ns=10L,
///   )
///   let step = b.push({ "resourceMetrics": [] }, watermark=2L)
///   assert_eq(
///     @metricstitch.decode_reorder_receipt(step.receipt()).buffer.pending_count(),
///     0,
///   )
/// }
/// ```
pub fn OtlpReorderBuffer::new(
  state : State,
  watermark~ : Int64,
  max_pending~ : Int32 = 128,
  max_delay_ns~ : Int64,
) -> OtlpReorderBuffer raise BufferError {
  let buffer : OtlpReorderBuffer = {
    reorder: ReorderBuffer::new(state, watermark~, max_pending~, max_delay_ns~),
    pending: [],
  }
  ignore(bounded_reorder_json(buffer.checkpoint()))
  buffer
}

///|
pub fn OtlpReorderBuffer::state(self : OtlpReorderBuffer) -> State {
  self.reorder.state()
}

///|
pub fn OtlpReorderBuffer::pending_count(self : OtlpReorderBuffer) -> Int32 {
  self.pending.length()
}

///|
/// Atomically queue supported OTLP Delta points and emit ready cumulative
/// points. Gauges pass through immediately, including repeated inputs. Original
/// empty containers are retained; emitted points keep their original resource,
/// scope, schema URLs, metric metadata and attributes. Groups are not coalesced.
pub fn OtlpReorderBuffer::push(
  self : OtlpReorderBuffer,
  request : Json,
  watermark~ : Int64,
) -> OtlpReorderStep raise BufferError {
  let owned = bounded_reorder_json(request)
  let (incoming, immediate) = capture_otlp(owned) catch {
    Invalid(message) => raise ReorderInvalid(message)
  }
  let step = self.reorder.push(incoming.map(e => e.point), watermark~)
  let entries = self.pending.copy()
  for entry in incoming {
    if !entries.any(e => e.point == entry.point) {
      entries.push(entry)
    }
  }
  let pending : Array[QueuedOtlp] = []
  for point in step.buffer.pending {
    let mut found : QueuedOtlp? = None
    for entry in entries {
      if entry.point == point {
        found = Some(entry)
        break
      }
    }
    guard found is Some(entry) else { abort("pending OTLP binding") }
    pending.push(entry)
  }
  guard immediate is { "resourceMetrics": Array(groups), .. } else {
    abort("captured request")
  }
  let resources = groups.copy()
  for point in step.points {
    let (series, _, end) = point.identity()
    let mut found : QueuedOtlp? = None
    for entry in entries {
      let (key, _, time) = entry.point.identity()
      if key == series && time == end {
        found = Some(entry)
        break
      }
    }
    guard found is Some(entry) else { abort("emitted OTLP binding") }
    let rendered = render_otlp_point(entry, point) catch {
      Invalid(message) => raise ReorderInvalid(message)
    }
    guard rendered is { "resourceMetrics": [group], .. } else {
      abort("rendered group")
    }
    resources.push(group)
  }
  let buffer : OtlpReorderBuffer = { reorder: step.buffer, pending, }
  ignore(bounded_reorder_json(buffer.checkpoint()))
  let output = bounded_reorder_json({
    "resourceMetrics": Json::array(resources),
  })
  let result : OtlpReorderStep = {
    buffer,
    request: output,
    duplicates: step.duplicates,
  }
  ignore(bounded_reorder_json(result.receipt()))
  result
}

///|
pub fn OtlpReorderBuffer::advance(
  self : OtlpReorderBuffer,
  watermark : Int64,
) -> OtlpReorderStep raise BufferError {
  self.push({ "resourceMetrics": [] }, watermark~)
}

///|
/// Versioned checkpoint includes every pending payload and its typed binding.
pub fn OtlpReorderBuffer::checkpoint(self : OtlpReorderBuffer) -> Json {
  {
    "version": 1,
    "buffer": self.reorder.checkpoint(),
    "pending": Json::array(self.pending.map(e => detached_json(e.request))),
  }
}

///|
/// Validate each single-point envelope and its exact binding to pending state.
/// Unknown fields, mismatched metadata/value/identity and extra payloads fail.
pub fn OtlpReorderBuffer::restore(
  value : Json,
) -> OtlpReorderBuffer raise BufferError {
  let owned = bounded_reorder_json(value)
  let (buffer, payloads) = try {
    let obj = fields(
      owned,
      ["version", "buffer", "pending"],
      "OTLP reorder checkpoint",
    )
    if required(obj, "version") != Json(1) {
      raise Invalid("unsupported OTLP reorder checkpoint version")
    }
    (required(obj, "buffer"), array(required(obj, "pending"), "pending"))
  } catch {
    Invalid(message) => raise ReorderInvalid(message)
  }
  let reorder = ReorderBuffer::restore(buffer)
  if payloads.length() != reorder.pending.length() {
    raise ReorderInvalid("pending OTLP payload count differs from typed state")
  }
  let entries : Array[QueuedOtlp] = []
  for i, request in payloads {
    guard request
      is {
        "resourceMetrics": [{ "scopeMetrics": [{ "metrics": [_], .. }], .. }],
        ..
      } else {
      raise ReorderInvalid(
        "pending payload must be a single resource/scope/metric/point",
      )
    }
    let (captured, _) = capture_otlp(request) catch {
      Invalid(message) => raise ReorderInvalid(message)
    }
    guard captured is [entry] && entry.point == reorder.pending[i] else {
      raise ReorderInvalid("pending OTLP payload does not match typed delta")
    }
    entries.push(entry)
  }
  { reorder, pending: entries, }
}

///|
pub fn OtlpReorderStep::receipt(self : OtlpReorderStep) -> Json {
  {
    "buffer": self.buffer.checkpoint(),
    "request": detached_json(self.request),
    "duplicates": Json(self.duplicates),
  }
}

///|
/// Structural validation for trusted local receipts, not authentication or a
/// delivery acknowledgement. Output and checkpoint correspondence is not proven.
pub fn decode_reorder_receipt(
  value : Json,
) -> OtlpReorderStep raise BufferError {
  let owned = bounded_reorder_json(value)
  let (checkpoint, request, duplicates) = try {
    let obj = fields(
      owned,
      ["buffer", "request", "duplicates"],
      "OTLP reorder receipt",
    )
    let request = required(obj, "request")
    let location = Ref("")
    ignore(process_otlp_impl(State::new(), request, location, cumulative=true)) catch {
      Invalid(message) =>
        raise Invalid("/request" + location.val + ": " + message)
    }
    let duplicates = int32_json(required(obj, "duplicates"))
    if duplicates < 0 {
      raise Invalid("negative duplicate count")
    }
    (required(obj, "buffer"), request, duplicates)
  } catch {
    Invalid(message) => raise ReorderInvalid(message)
  }
  { buffer: OtlpReorderBuffer::restore(checkpoint), request, duplicates, }
}
