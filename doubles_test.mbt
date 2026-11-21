///|
test "Double sums resume and preserve integer checkpoint compatibility" {
  let p : @metricstitch.DoubleSample = {
    series: "float",
    start: 1L,
    end: 2L,
    value: 1.25,
  }
  let first = @metricstitch.State::new().apply_doubles([p])
  let saved = @metricstitch.parse_input(first.state.checkpoint().stringify())
  assert_true(saved is { "version": Number(2.0, ..), .. })
  let resumed = @metricstitch.State::restore(saved)
  let next : @metricstitch.DoubleSample = {
    ..p,
    start: 2L,
    end: 3L,
    value: 0.75,
  }
  assert_eq(resumed.apply_doubles([next]).points[0].value, 2.0)
  assert_eq(resumed.apply_doubles([p]).duplicates, 1)
  let integer : @metricstitch.Sample = {
    series: "int",
    start: 1L,
    end: 2L,
    value: 9007199254740993L,
  }
  let mixed = resumed.apply([integer]).state
  assert_eq(
    @metricstitch.State::restore(mixed.checkpoint()).checkpoint(),
    mixed.checkpoint(),
  )
  assert_true(
    @metricstitch.State::new().apply([integer]).state.checkpoint()
    is { "version": Number(1.0, ..), .. },
  )
  assert_true(
    (Some(mixed.apply([{ ..integer, series: "float", }])) catch { _ => None })
    is None,
  )
}

///|
test "Double invalid values overflow and late batch failures retain state" {
  let p : @metricstitch.DoubleSample = {
    series: "x",
    start: 1L,
    end: 2L,
    value: 1.0e308,
  }
  let state = @metricstitch.State::new().apply_doubles([p]).state
  let saved = state.checkpoint()
  let infinity = 1.0e308 * 2.0
  for value in [-1.0, 1.0e308, infinity, infinity - infinity] {
    assert_true(
      (Some(state.apply_doubles([{ ..p, start: 2L, end: 3L, value, }])) catch {
        _ => None
      })
      is None,
    )
  }
  assert_true(
    (Some(
      state.apply_doubles([
        { ..p, start: 2L, end: 3L, value: 0.0, },
        { ..p, start: 4L, end: 5L, value: 0.0, },
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
  assert_eq(state.checkpoint(), saved)
  assert_eq(
    state.apply_doubles([{ ..p, start: 2L, end: 3L, value: 0.0, }]).points[0].value,
    1.0e308,
  )
}

///|
test "OTLP Double values are not coerced and mixed kind batch fails atomically" {
  let state = @metricstitch.State::new()
  let raw = request("1", "2", "7")
    .stringify()
    .replace(old="\"asInt\":\"7\"", new="\"asDouble\":1.25")
  let first = @metricstitch.process_otlp(state, @metricstitch.parse_input(raw))
  let next = request("2", "3", "7")
    .stringify()
    .replace(old="\"asInt\":\"7\"", new="\"asDouble\":0.75")
  let output = @metricstitch.process_otlp(
    @metricstitch.State::restore(first.state.checkpoint()),
    @metricstitch.parse_input(next),
  )
  assert_true(output.request.stringify().contains("\"asDouble\":2"))
  assert_true(
    (Some(@metricstitch.process_otlp(first.state, request("2", "3", "7"))) catch {
      _ => None
    })
    is None,
  )
}
