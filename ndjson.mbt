///|
/// Immutable bounded UTF-8 line framing. A feed chunk is at most 64 KiB;
/// records are at most max_record_bytes excluding LF, including an optional CR.
pub struct NdjsonDecoder {
  priv pending : Bytes
  priv limit : Int32
  priv completed : Int64
}

///|
pub(all) struct NdjsonLines {
  decoder : NdjsonDecoder
  lines : Array[String]
}

///|
pub fn NdjsonDecoder::new(
  max_record_bytes~ : Int32 = 4000000,
) -> NdjsonDecoder raise StitchError {
  if max_record_bytes <= 0 || max_record_bytes > 4000000 {
    raise Invalid("record byte limit must be in 1..4000000")
  }
  { pending: b"", limit: max_record_bytes, completed: 0L, }
}

///|
fn decode_record(
  bytes : Array[Byte],
  ordinal : Int64,
) -> String raise StitchError {
  let size = bytes.length() - (if bytes.last() == Some(b'\r') { 1 } else { 0 })
  @utf8.decode(Bytes::from_array(bytes[0:size])[:], ignore_bom=false) catch {
    _ =>
      raise Invalid(
        "invalid UTF-8 at NDJSON physical line " + ordinal.to_string(),
      )
  }
}

///|
/// Delimit LF/CRLF without lossy decoding. Partial multibyte characters stay in
/// the byte buffer until the complete record arrives. Failure preserves self.
pub fn NdjsonDecoder::feed(
  self : NdjsonDecoder,
  chunk : Bytes,
) -> NdjsonLines raise StitchError {
  if chunk.length() > 65536 {
    raise Invalid("NDJSON feed exceeds 64 KiB")
  }
  let pending = self.pending.to_array()
  let lines : Array[String] = []
  let mut completed = self.completed
  for byte in chunk {
    if byte == b'\n' {
      if completed == 9223372036854775807L {
        raise Invalid("NDJSON physical line count overflow")
      }
      completed += 1L
      lines.push(decode_record(pending, completed))
      pending.clear()
    } else {
      if pending.length() == self.limit {
        raise Invalid("NDJSON record exceeds configured byte limit")
      }
      pending.push(byte)
    }
  }
  {
    decoder: { ..self, pending: Bytes::from_array(pending[:]), completed, },
    lines,
  }
}

///|
/// Return the final unterminated record, or None after a terminal LF/empty file.
/// Blank framed records are retained; the replay session will refuse them.
pub fn NdjsonDecoder::finish(self : NdjsonDecoder) -> String? raise StitchError {
  if self.pending.is_empty() {
    return None
  }
  if self.completed == 9223372036854775807L {
    raise Invalid("NDJSON physical line count overflow")
  }
  Some(decode_record(self.pending.to_array(), self.completed + 1L))
}
