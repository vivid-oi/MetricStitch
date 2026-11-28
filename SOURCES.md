# Sources and licenses

* Adjacent OTLP compaction and pending-gap reports are authored here under
  Apache-2.0 and use the existing strict OTLP profile. Their synthetic unit cases
  are project-authored. File checks reuse the credited session adaptation and
  the project's complete-envelope comparison pattern; no upstream compactor or
  diagnostic implementation is copied.

* `checks/stream.mbtx` reuses the credited session adaptation for CRLF/replay
  checks. Its >4 MB stress case adds synthetic metric-description text and JSON
  whitespace. NDJSON framing/session/stream publication code is authored here;
  the existing credited temporary-file publication pattern is retained.

* `checks/differential.mbtx` creates synthetic multi-interval cases and compares
  outputs against Collector Contrib 0.166.0 (Apache-2.0), using the existing
  test-only community OTLP models. No upstream processor or test code is copied.
  https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.166.0/processor/deltatocumulativeprocessor

* Project implementation, tests and replay adapter are authored for MetricStitch,
  Apache-2.0.
* Exponential histogram behavior follows the OpenTelemetry model/protocol; the
  merge implementation is authored here using integer index folding, not copied
  from Collector. `examples/exponential` adapts the already credited pinned OTLP
  example's population and adds two intervals and a finer-scale representation.
  The replay changes only that official exponential example's interval times.
  https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponentialhistogram
* `examples/upstream-metrics.json` is copied unchanged from OpenTelemetry Proto,
  commit `d31f7acf9d461fd0601077de516ac1eb7051422f`, file `examples/metrics.json`.
  Source https://github.com/open-telemetry/opentelemetry-proto/blob/d31f7acf9d461fd0601077de516ac1eb7051422f/examples/metrics.json
  License Apache-2.0, included in `examples/UPSTREAM-LICENSE`.
* `checks/replay.mbtx` derives an Int64 monotonic-Sum profile from the official
  example at runtime. It removes the other metric examples, replaces asDouble
  with asInt, and sets explicit contiguous intervals. A separate run exercises
  asDouble and refusal of a numeric-kind switch. Those edits are documented
  synthetic test inputs. The production converter rejects the original example.
  The same fixture's explicit histogram is replayed twice with contiguous edited
  timestamps. Its buckets, count, sum and extrema retain the upstream values.
  A mixed replay retains the official Counter, Gauge and Histogram, adapts the
  two interval start times and verifies that Gauge content survives unchanged.
  An additional counter run uses 9007199254740993 to test exact Int64 export.
* OpenTelemetry metrics data model is the behavioral reference, not copied code.
  https://opentelemetry.io/docs/specs/otel/metrics/data-model/
* `moonbitlang/async` 0.22.5 provides CLI filesystem/process/runtime adapters,
  Apache-2.0. https://github.com/moonbitlang/async
* `examples/session.json` adapts the pinned official OTLP example into two
  contiguous Counter/Gauge/Histogram requests. It omits example point and scope
  attributes, uses counter deltas 5 and 2.5, and Gauge samples 10 and 11.
  These are synthetic demonstration edits under Apache-2.0, not production data.
* `checks/reorder.mbtx` derives a third interval from that session, using Counter
  delta 3.5, Gauge value 12 and shifted timestamps; histogram population/buckets
  remain unchanged. It submits arrival order 3,1,2 and validates recovery/export.
* `checks/protocol.mbtx` uses `moonbit-community/opentelemetry` 0.1.8 generated
  protocol models and `moonbitlang/protobuf` 0.1.3 as test-only dependencies.
  Both are Apache-2.0. No processing code is copied from these projects.
  https://github.com/moonbit-community/opentelemetry.mbt
  https://github.com/moonbitlang/protobuf
* The root Apache-2.0 license text comes from the owner's MoonPOMerge repository.
* `checks/collector.mbtx` runs the official OpenTelemetry Collector core 0.166.0
  binary as an external test dependency (Apache-2.0); no binary is vendored.
  Receiver/file-exporter configuration follows the upstream documentation:
  https://github.com/open-telemetry/opentelemetry-collector/tree/v0.166.0/receiver/otlpreceiver
  https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.166.0/exporter/fileexporter
* `cli/publish.mbt` adapts the Apache-2.0 temporary-file publication pattern from
  https://github.com/vivid-oi/MoonPOMerge/blob/974bf668b480334dd2b38b1eaa6744faf9b26471/cmd/main/driver.mbt
  That source credits FontPin and MBTRelMask.
