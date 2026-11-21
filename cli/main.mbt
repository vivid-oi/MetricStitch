///|
async fn read_json(path : String) -> Json {
  let file = @fs.open(path[:], mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular || file.size() > 4000000L {
    fail("expected regular JSON file at most 4 MB")
  }
  let bytes : Array[Byte] = []
  while file.read_some(max_len=65536) is Some(chunk) {
    if chunk.length() > 4000000 - bytes.length() {
      fail("JSON exceeds 4 MB")
    }
    for byte in chunk {
      bytes.push(byte)
    }
  }
  @metricstitch.parse_input(@utf8.decode(Bytes::from_array(bytes[:])[:]))
}

///|
async fn execute() -> Unit {
  let args = @env.args()
  let sequence = args.length() > 1 && args[1] == "replay-to"
  let to_file = args.length() > 1 && (args[1] == "apply-to" || sequence)
  let checking = args.length() > 1 && args[1] == "check"
  let valid = if to_file {
    args.length() == 4 || args.length() == 5
  } else if checking {
    args.length() == 3 || args.length() == 4
  } else {
    args.length() == 2 || args.length() == 3
  }
  if !valid {
    fail(
      "usage: metricstitch INPUT.json [CHECKPOINT.json] | check INPUT.json [CHECKPOINT.json] | apply-to INPUT.json OUTPUT.json [PREVIOUS_RECEIPT.json] | replay-to SEQUENCE.json OUTPUT.json [PREVIOUS_RECEIPT.json]",
    )
  }
  let state = if to_file && args.length() == 5 {
    let receipt = read_json(args[4])
    guard receipt is Object(obj) &&
      obj.length() == 3 &&
      receipt
      is {
        "checkpoint": checkpoint,
        "request": Object(_),
        "duplicates": Number(count, ..),
        ..
      } &&
      count >= 0.0 &&
      count.floor() == count &&
      !count.is_inf() else {
      fail(
        "expected complete previous receipt with checkpoint, request and duplicate count",
      )
    }
    @metricstitch.State::restore(checkpoint)
  } else if checking && args.length() == 4 {
    @metricstitch.State::restore(read_json(args[3]))
  } else if !to_file && !checking && args.length() == 3 {
    @metricstitch.State::restore(read_json(args[2]))
  } else {
    @metricstitch.State::new()
  }
  let input = args[if to_file || checking { 2 } else { 1 }]
  let request = read_json(input)
  if checking {
    let diagnostic = @metricstitch.validate_otlp(state, request)
    let report : Json = match diagnostic {
      None => { "valid": true, "diagnostic": null }
      Some(d) =>
        {
          "valid": false,
          "diagnostic": {
            "pointer": Json(d.pointer),
            "message": Json(d.message),
          },
        }
    }
    @stdio.stdout.write(report.stringify() + "\n")
    if diagnostic is Some(_) {
      exit_process(2)
    }
    return
  }
  let result = if sequence {
    guard request is Object(obj) &&
      obj.length() == 1 &&
      request is { "requests": Array(requests), .. } else {
      fail("sequence file must contain exactly a requests array")
    }
    @metricstitch.process_sequence(state, requests)
  } else {
    @metricstitch.process_otlp(state, request)
  }
  let receipt : Json = {
    "checkpoint": result.state.checkpoint(),
    "request": result.request,
    "duplicates": Json(result.duplicates),
  }
  let output = receipt.stringify() + "\n"
  if @utf8.encode(output).length() > 4000000 {
    fail("receipt exceeds 4 MB")
  }
  if to_file {
    publish_receipt(args[3], @utf8.encode(output))
  } else {
    @stdio.stdout.write(output)
  }
}

///|
#cfg(target="native")
extern "C" fn exit_process(code : Int32) -> Unit = "exit"

///|
#cfg(target="wasm")
#unsafe_skip_stub_check
fn exit_process(code : Int32) -> Unit = "moonbitlang/async" "runtime/exit"

///|
async fn main {
  execute() catch {
    @metricstitch.Invalid(message) => {
      @stdio.stderr.write(message + "\n")
      exit_process(2)
    }
    error => {
      @stdio.stderr.write(error.to_string() + "\n")
      exit_process(2)
    }
  }
}
