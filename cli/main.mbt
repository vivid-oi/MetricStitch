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
  if args.length() > 1 && args[1] == "coarsen-to" {
    if args.length() != 5 {
      fail("usage: coarsen-to INPUT.json BOUNDS.json OUTPUT.json")
    }
    guard read_json(args[3]) is Array(values) else {
      fail("bounds must be a JSON number array")
    }
    let bounds = values.map(v => {
      guard v is Number(n, ..) else { fail("bounds must be JSON numbers") }
      n
    })
    let result = @metricstitch.coarsen_otlp_histograms(
      read_json(args[2]),
      bounds,
    )
    let encoded = @utf8.encode(result.stringify() + "\n")
    if encoded.length() > 4000000 {
      fail("coarsened OTLP exceeds 4 MB")
    }
    publish_receipt(args[4], encoded)
    return
  }
  if args.length() > 1 && args[1] == "merge-state" {
    if args.length() != 5 {
      fail(
        "usage: merge-state LEFT_CHECKPOINT.json RIGHT_CHECKPOINT.json OUTPUT.json",
      )
    }
    let left = @metricstitch.State::restore(read_json(args[2]))
    let right = @metricstitch.State::restore(read_json(args[3]))
    let result = @utf8.encode(
      left.merge_disjoint(right).checkpoint().stringify() + "\n",
    )
    if result.length() > 4000000 {
      fail("merged checkpoint exceeds 4 MB")
    }
    publish_receipt(args[4], result)
    return
  }
  if args.length() > 1 && args[1] == "reorder-to" {
    if args.length() != 5 && args.length() != 6 {
      fail(
        "usage: reorder-to INPUT.json OUTPUT.json WATERMARK_NS [PREVIOUS_RECEIPT.json]",
      )
    }
    if args[4].is_empty() || args[4].to_array().any(c => c < '0' || c > '9') {
      fail("watermark must be positive decimal Unix nanoseconds")
    }
    let watermark = @string.parse_int64(args[4][:], base=10)
    if watermark <= 0L {
      fail("watermark must be positive Unix nanoseconds")
    }
    let buffer = if args.length() == 6 {
      @metricstitch.decode_reorder_receipt(read_json(args[5])).buffer
    } else {
      @metricstitch.OtlpReorderBuffer::new(
        @metricstitch.State::new(),
        watermark=1L,
        max_delay_ns=60000000000L,
      )
    }
    let result = buffer.push(read_json(args[2]), watermark~)
    let encoded = @utf8.encode(result.receipt().stringify() + "\n")
    if encoded.length() > 4000000 {
      fail("reorder receipt exceeds 4 MB")
    }
    publish_receipt(args[3], encoded)
    return
  }
  if args.length() > 1 && (args[1] == "export" || args[1] == "inspect") {
    let exporting = args[1] == "export"
    if args.length() != (if exporting { 4 } else { 3 }) {
      fail("usage: export RECEIPT.json OUTPUT.json | inspect RECEIPT.json")
    }
    let raw = read_json(args[2])
    let (request, report) : (Json, Json) = if raw is Object(obj) &&
      obj.contains("buffer") {
      let receipt = @metricstitch.decode_reorder_receipt(raw)
      (
        receipt.request,
        {
          "state": receipt.buffer.state().summary(),
          "pending": Json(receipt.buffer.pending_count()),
          "duplicates": Json(receipt.duplicates),
        },
      )
    } else {
      let receipt = @metricstitch.decode_receipt(raw)
      (
        receipt.request,
        {
          "state": receipt.state.summary(),
          "duplicates": Json(receipt.duplicates),
        },
      )
    }
    if exporting {
      let output = @utf8.encode(request.stringify() + "\n")
      if output.length() > 4000000 {
        fail("export exceeds 4 MB")
      }
      publish_receipt(args[3], output)
    } else {
      @stdio.stdout.write(report.stringify() + "\n")
    }
    return
  }
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
    @metricstitch.decode_receipt(read_json(args[4])).state
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
    let diagnostic = @metricstitch.diagnose_otlp(state, request)
    let report : Json = match diagnostic {
      None => { "valid": true, "diagnostic": null }
      Some(d) =>
        {
          "valid": false,
          "diagnostic": {
            "code": Json(d.code.code()),
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
  let receipt = result.receipt()
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
