///|
test "UTF-8 records survive every byte split and terminal line convention" {
  let bytes : Bytes = [
    b'{', b'}', b'\r', b'\n', 0xe4, 0xb8, 0xad, b'\n', 0xf0, 0x9f, 0x98, 0x80,
  ]
  for cut in 0..<=bytes.length() {
    let first = @metricstitch.NdjsonDecoder::new().feed(bytes[0:cut].to_owned())
    let second = first.decoder.feed(bytes[cut:].to_owned())
    assert_eq(first.lines + second.lines, ["{}", "中"])
    assert_eq(second.decoder.finish(), Some("😀"))
  }
  let mut decoder = @metricstitch.NdjsonDecoder::new()
  let lines : Array[String] = []
  for byte in bytes {
    let step = decoder.feed(Bytes::from_array([byte]))
    decoder = step.decoder
    for line in step.lines {
      lines.push(line)
    }
  }
  assert_eq(lines, ["{}", "中"])
  assert_eq(decoder.finish(), Some("😀"))
  assert_true(
    @metricstitch.NdjsonDecoder::new().feed(b"{}\n").decoder.finish() is None,
  )
}

///|
test "framing limits invalid UTF-8 and recovery are strict" {
  let base = @metricstitch.NdjsonDecoder::new(max_record_bytes=3)
  let held = base.feed(b"{} ").decoder
  assert_true((Some(held.feed(b"x")) catch { _ => None }) is None)
  assert_eq(held.finish(), Some("{} "))
  assert_eq(held.feed(b"\n").lines, ["{} "])
  assert_eq(base.feed(b"{}\r\n").lines, ["{}"])
  assert_true((Some(base.feed(b"\xff\n")) catch { _ => None }) is None)
  let partial = base.feed(b"\xe4").decoder
  assert_true((Some(partial.finish()) catch { _ => None }) is None)
  assert_eq(partial.feed(b"\xb8\xad\n").lines, ["中"])
  assert_true(
    (Some(base.feed(Bytes::from_array(Array::make(65537, b'x')))) catch {
      _ => None
    })
    is None,
  )
  for limit in [0, 4000001] {
    assert_true(
      (Some(@metricstitch.NdjsonDecoder::new(max_record_bytes=limit)) catch {
        _ => None
      })
      is None,
    )
  }
  assert_eq(base.feed(b"\n\n").lines, ["", ""])
}

///|
test "replay records restore continuations and preserve strict retry semantics" {
  let base = @metricstitch.ReplaySession::new(@metricstitch.State::new())
  let first = base.apply_line(request("1", "2", "7").stringify())
  let restored = @metricstitch.decode_replay_record(
    @metricstitch.parse_input(first.receipt().stringify()),
  )
  assert_eq(restored.ordinal, 1L)
  let retry = restored.session.apply_line(request("1", "2", "7").stringify())
  assert_eq(retry.duplicates, 1)
  assert_eq(retry.ordinal, 2L)
  let second = @metricstitch.ReplaySession::restore(
    restored.session.checkpoint(),
  ).apply_line(request("2", "3", "5").stringify())
  assert_eq(emitted_ints(second.request), ["12"])
  assert_eq(base.record_count(), 0L)
  assert_eq(first.session.record_count(), 1L)
}

///|
test "record errors identify the ordinal and leave session reusable" {
  let base = @metricstitch.ReplaySession::new(@metricstitch.State::new())
  let first = base.apply_line(request("1", "2", "7").stringify())
  let saved = first.session.checkpoint()
  for
    line in [
      "",
      "{",
      "{\"resourceMetrics\":[]}\n",
      request("3", "4", "1").stringify(),
    ] {
    let failed = Some(first.session.apply_line(line)) catch {
      @metricstitch.Invalid(message) => {
        assert_true(message.has_prefix("/records/2:"))
        None
      }
    }
    assert_true(failed is None)
    assert_eq(first.session.checkpoint(), saved)
  }
  let record = first.receipt()
  guard record is Object(fields) else { fail("receipt") }
  let copy = fields.copy()
  copy["ordinal"] = Json("2")
  assert_true(
    (Some(@metricstitch.decode_replay_record(Json::object(copy))) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(
      @metricstitch.ReplaySession::restore({
        "version": 2,
        "records": "1",
        "state": saved,
      }),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "replay ordinal maximum rejects increment without wrapping" {
  let state = @metricstitch.State::new()
  let session = @metricstitch.ReplaySession::restore({
    "version": 1,
    "records": "9223372036854775807",
    "state": state.checkpoint(),
  })
  assert_true(
    (Some(session.apply_line("{\"resourceMetrics\":[]}")) catch { _ => None })
    is None,
  )
  assert_eq(session.record_count(), 9223372036854775807L)
}
