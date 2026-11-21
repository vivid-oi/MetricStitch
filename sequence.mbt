///|
/// Convert at most 1024 requests in order as one transaction. ResourceMetrics
/// groups remain ordered and are not coalesced. A later error returns no partial
/// receipt or state, and identifies its zero-based request index.
///
/// ```mbt check
/// test {
///   let state = @metricstitch.State::new()
///   let result = @metricstitch.process_sequence(state, [{ "resourceMetrics": [] }])
///   assert_eq(result.state.checkpoint(), state.checkpoint())
/// }
/// ```
pub fn process_sequence(
  state : State,
  requests : Array[Json],
) -> OtlpStep raise StitchError {
  if requests.length() > 1024 {
    raise Invalid("sequence exceeds 1024 requests")
  }
  let resources : Array[Json] = []
  let mut current = state
  let mut duplicates = 0
  for i, request in requests {
    let step = process_otlp(current, request) catch {
      Invalid(message) => raise Invalid("/requests/" + i.to_string() + message)
    }
    current = step.state
    duplicates += step.duplicates
    guard step.request is { "resourceMetrics": Array(groups), .. } else {
      abort("converted request shape")
    }
    for group in groups {
      resources.push(group)
    }
  }
  {
    state: current,
    request: { "resourceMetrics": Json::array(resources) },
    duplicates,
  }
}
