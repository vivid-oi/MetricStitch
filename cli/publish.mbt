///|
// Publication pattern adapted from the owner's Apache-2.0 MoonPOMerge CLI.
async fn publish_receipt(path : String, bytes : Bytes) -> Unit {
  @async.protect_from_cancel(() => {
    publish_stream_output(path, async fn(file) { file.write(bytes) })
  })
}

///|
// Long writers remain cancellable. Only allocation/publication are protected;
// unwinding closes the descriptor and removes the owned temporary file.
async fn publish_stream_output(
  path : String,
  writer : async (@fs.File) -> Unit,
) -> Unit {
  guard @env.rand(16) is Some(random) else {
    fail("cannot allocate temporary name")
  }
  let hex = "0123456789abcdef".to_array()
  let suffix = StringBuilder()
  for byte in random {
    suffix.write_char(hex[byte.to_int() >> 4])
    suffix.write_char(hex[byte.to_int() & 15])
  }
  let temp = path + "." + suffix.to_string() + ".pending"
  let file = @async.protect_from_cancel(() => {
    @fs.create(temp[:], allow_existing=false, permission=0o600)
  })
  let mut published = false
  defer (if !published {
    @fs.remove(temp[:]) catch {
      _ => @stdio.stderr.write("cannot remove temporary receipt " + temp + "\n")
    }
  })
  {
    defer file.close()
    writer(file)
    file.sync()
  }
  @async.protect_from_cancel(() => {
    @fs.rename(temp[:], path[:], replace=false)
    published = true
  })
}
