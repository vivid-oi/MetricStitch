///|
fn main raise {
  for n in [100, 1000, 10000] {
    let batch : Array[@metricstitch.Sample] = []
    for i in 0..<n {
      batch.push({ series: "s" + i.to_string(), start: 1L, end: 2L, value: 1L, })
    }
    let inserts : Array[Double] = []
    let updates_us : Array[Double] = []
    let retries : Array[Double] = []
    for repetition in 0..<6 {
      let initial = @metricstitch.State::new(max_series=n)
      let start = @bench.monotonic_clock_start()
      let populated = initial.apply(batch).state
      let insert = @bench.monotonic_clock_end(start)
      let updates = batch.map(p => { ..p, start: 2L, end: 3L, })
      let start = @bench.monotonic_clock_start()
      let next = populated.apply(updates)
      let update = @bench.monotonic_clock_end(start)
      let start = @bench.monotonic_clock_start()
      let retry = next.state.apply(updates)
      let duplicate = @bench.monotonic_clock_end(start)
      assert_eq(retry.duplicates, n)
      assert_eq(next.points.length(), n)
      assert_eq(next.points[n - 1].value, 2L)
      if repetition > 0 {
        inserts.push(insert)
        updates_us.push(update)
        retries.push(duplicate)
      }
    }
    inserts.sort()
    updates_us.sort()
    retries.sort()
    println(
      "series=\{n} insert_us=\{inserts[2]} update_us=\{updates_us[2]} retry_us=\{retries[2]}",
    )
  }
}
