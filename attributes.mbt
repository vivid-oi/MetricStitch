///|
fn signed_decimal(value : Json, path : String) -> Int64 raise StitchError {
  let s = text(value, path)
  let begin = if s.has_prefix("-") { 1 } else { 0 }
  if s.length() == begin {
    raise Invalid(path + ": expected signed decimal")
  }
  for i in begin..<s.length() {
    let ch = s.code_unit_at(i)
    if ch < '0' || ch > '9' {
      raise Invalid(path + ": expected signed decimal")
    }
  }
  @string.parse_int64(s[:], base=10) catch {
    _ => raise Invalid(path + ": exceeds Int64 range")
  }
}

///|
// Canonical values are used only for identity. Outgoing metadata retains the
// caller's original representation. Container limits bound direct Json callers.
fn attribute_value(
  value : Json,
  depth : Int32,
  budget : Ref[Int32],
) -> Json raise StitchError {
  budget.val -= 1
  if depth > 16 || budget.val < 0 {
    raise Invalid("attribute nesting or value budget exceeded")
  }
  let obj = fields(
    value,
    [
      "stringValue", "boolValue", "intValue", "doubleValue", "bytesValue", "arrayValue",
      "kvlistValue",
    ],
    "attribute.value",
  )
  if obj.length() != 1 {
    raise Invalid("attribute.value requires exactly one value kind")
  }
  let (kind, data) = obj.iter().next().unwrap()
  match kind {
    "stringValue" => { "stringValue": Json(text(data, kind)) }
    "boolValue" => {
      if data != Json(true) && data != Json(false) {
        raise Invalid("boolValue must be boolean")
      }
      { "boolValue": data }
    }
    "intValue" => { "intValue": Json(signed_decimal(data, kind).to_string()) }
    "doubleValue" => {
      guard data is Number(number, ..) && !number.is_nan() && !number.is_inf() else {
        raise Invalid("doubleValue must be a finite JSON number")
      }
      { "doubleValue": Json(if number == 0.0 { 0.0 } else { number }) }
    }
    "bytesValue" => {
      let encoded = text(data, kind)
      let bytes = @base64.decode(encoded[:]) catch {
        _ => raise Invalid("invalid base64 bytesValue")
      }
      { "bytesValue": Json(@base64.encode(bytes[:])) }
    }
    "arrayValue" => {
      let container = fields(data, ["values"], kind)
      let values = array(
        container.get("values").unwrap_or(Json::array([])),
        kind,
      )
      {
        "arrayValue": {
          "values": Json::array(
            values.map(v => attribute_value(v, depth + 1, budget)),
          ),
        },
      }
    }
    "kvlistValue" => {
      let container = fields(data, ["values"], kind)
      {
        "kvlistValue": {
          "values": attributes(
            container.get("values").unwrap_or(Json::array([])),
            depth=depth + 1,
            budget~,
          ),
        },
      }
    }
    _ => raise Invalid("unsupported attribute kind")
  }
}
