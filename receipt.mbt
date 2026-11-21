///|
/// Serialize conversion output and its matching next state as one receipt.
pub fn OtlpStep::receipt(self : OtlpStep) -> Json {
  {
    "checkpoint": self.state.checkpoint(),
    "request": self.request,
    "duplicates": Json(self.duplicates),
  }
}

///|
/// Validate trusted local receipt structure, checkpoint and cumulative request
/// profile. Historical output points are validated independently. This does not
/// authenticate a receipt or prove that its output was delivered.
///
/// ```mbt check
/// test {
///   let step = @metricstitch.process_otlp(@metricstitch.State::new(), {
///     "resourceMetrics": [],
///   })
///   let restored = @metricstitch.decode_receipt(step.receipt())
///   assert_eq(restored.state.checkpoint(), step.state.checkpoint())
/// }
/// ```
pub fn decode_receipt(value : Json) -> OtlpStep raise StitchError {
  let obj = fields(value, ["checkpoint", "request", "duplicates"], "receipt")
  let state = State::restore(required(obj, "checkpoint"))
  let request = required(obj, "request")
  let location = Ref("")
  ignore(process_otlp_impl(State::new(), request, location, cumulative=true)) catch {
    Invalid(message) =>
      raise Invalid("/request" + location.val + ": " + message)
  }
  guard required(obj, "duplicates") is Number(count, ..) &&
    !count.is_inf() &&
    count >= 0.0 &&
    count <= 2147483647.0 &&
    count.floor() == count else {
    raise Invalid("receipt duplicates must be a nonnegative Int32")
  }
  { state, request, duplicates: count.to_int(), }
}
