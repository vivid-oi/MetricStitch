///|
/// Stable programmatic categories. Messages remain descriptive, not an API.
#derive(Eq)
pub(all) enum IssueCode {
  InvalidInput
  UnsupportedData
  NoncontiguousInterval
  ConflictingRetry
  SeriesLimit
  NumericOverflow
  KindChanged
}

///|
pub extend IssueCode with Eq::{equal, not_equal}

///|
/// Stable snake_case representation used by the CLI JSON report.
pub fn IssueCode::code(self : IssueCode) -> String {
  match self {
    InvalidInput => "invalid_input"
    UnsupportedData => "unsupported_data"
    NoncontiguousInterval => "noncontiguous_interval"
    ConflictingRetry => "conflicting_retry"
    SeriesLimit => "series_limit"
    NumericOverflow => "numeric_overflow"
    KindChanged => "kind_changed"
  }
}

///|
pub(all) struct DiagnosticDetail {
  code : IssueCode
  pointer : String
  message : String
}

///|
fn interval_issue(
  start : Int64,
  end : Int64,
  old_start : Int64,
  old_end : Int64,
) -> IssueCode {
  if start == old_start && end == old_end {
    ConflictingRetry
  } else {
    NoncontiguousInterval
  }
}

///|
/// Read-only classification produced at the failing check, without parsing
/// error text. Existing Diagnostic and StitchError::Invalid remain unchanged.
///
/// ```mbt check
/// test {
///   let d = @metricstitch.diagnose_otlp(@metricstitch.State::new(), {
///     "unknown": 1,
///   })
///   assert_true(d is Some({ code: UnsupportedData, .. }))
/// }
/// ```
pub fn diagnose_otlp(state : State, request : Json) -> DiagnosticDetail? {
  let location = Ref("")
  let issue = Ref(InvalidInput)
  ignore(process_otlp_impl(state, request, location, issue~)) catch {
    Invalid(message) =>
      return Some({ code: issue.val, pointer: location.val, message, })
  }
  None
}
