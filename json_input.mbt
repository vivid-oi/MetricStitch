///|
/// Parse bounded JSON with duplicate decoded object keys rejected. A Json value
/// passed directly to process_otlp must already have unambiguous object keys.
pub fn parse_input(source : String) -> Json raise StitchError {
  if source.length() > 4000000 {
    raise Invalid("JSON exceeds 4M code units")
  }
  let value = @json.parse(source[:], max_nesting_depth=64) catch {
    e => raise Invalid(e.to_string())
  }
  let stack : Array[Map[String, Bool]] = []
  let mut i = 0
  while i < source.length() {
    match source.code_unit_at(i) {
      '{' => {
        stack.push(Map([]))
        i += 1
      }
      '}' => {
        ignore(stack.pop())
        i += 1
      }
      '"' => {
        let start = i
        i += 1
        while source.code_unit_at(i) != '"' {
          if source.code_unit_at(i) == '\\' {
            i += 1
          }
          i += 1
        }
        i += 1
        let mut next = i
        while next < source.length() &&
              " \t\r\n".contains(source[next:next + 1]) {
          next += 1
        }
        if next < source.length() && source.code_unit_at(next) == ':' {
          let decoded = @json.parse(source[start:i]) catch {
            e => raise Invalid(e.to_string())
          }
          let key = text(decoded, "object key")
          let seen = stack[stack.length() - 1]
          if seen.contains(key) {
            raise Invalid("duplicate JSON key " + key)
          }
          seen[key] = true
        }
      }
      _ => i += 1
    }
  }
  value
}
