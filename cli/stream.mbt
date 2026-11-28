///|
async fn stream_records(
  input_path : String,
  output_path : String,
  session : @metricstitch.ReplaySession,
  exporting~ : Bool,
) -> Unit {
  let input = @fs.open(input_path[:], mode=ReadOnly)
  defer input.close()
  if input.kind() != Regular {
    fail("NDJSON input must be a regular UTF-8 file")
  }
  let mut decoder = @metricstitch.NdjsonDecoder::new()
  let mut current = session
  let mut previous : Int64? = None
  publish_stream_output(output_path, async fn(output) {
    async fn consume(line : String) -> Unit {
      let value = if exporting {
        let record = @metricstitch.decode_replay_record(
          @metricstitch.parse_input(line),
        )
        if previous is Some(n) &&
          (n == 9223372036854775807L || record.ordinal != n + 1L) {
          fail("stream export requires contiguous increasing record ordinals")
        }
        previous = Some(record.ordinal)
        record.request
      } else {
        let record = current.apply_line(line)
        current = record.session
        record.receipt()
      }
      let bytes = @utf8.encode(value.stringify() + "\n")
      if bytes.length() > 4000000 {
        fail("stream output record exceeds 4 MB")
      }
      output.write(bytes)
    }
    while input.read_some(max_len=65536) is Some(chunk) {
      let framed = decoder.feed(chunk)
      decoder = framed.decoder
      for line in framed.lines {
        consume(line)
      }
    }
    if decoder.finish() is Some(last) {
      consume(last)
    }
  })
}
