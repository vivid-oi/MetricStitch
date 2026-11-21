///|
/// pointer identifies the nearest resource, scope, metric or data-point container
/// using RFC 6901 syntax. An empty pointer identifies the request root.
pub(all) struct Diagnostic {
  pointer : String
  message : String
}

///|
/// Convert supported Delta metrics atomically. Errors retain the Invalid
/// constructor and include the indexed input location in their message.
pub fn process_otlp(
  state : State,
  request : Json,
) -> OtlpStep raise StitchError {
  let location = Ref("")
  process_otlp_impl(state, request, location) catch {
    Invalid(message) => raise Invalid(location.val + ": " + message)
  }
}

///|
/// Validate with the same conversion and state checks as process_otlp, returning
/// the first diagnostic. Input and state remain available for correction/retry.
///
/// ```mbt check
/// test {
///   let state = @metricstitch.State::new()
///   assert_true(
///     @metricstitch.validate_otlp(state, { "resourceMetrics": [] }) is None,
///   )
/// }
/// ```
pub fn validate_otlp(state : State, request : Json) -> Diagnostic? {
  let location = Ref("")
  ignore(process_otlp_impl(state, request, location)) catch {
    Invalid(message) => return Some({ pointer: location.val, message, })
  }
  None
}
