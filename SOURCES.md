# Sources and licenses

* Project implementation, tests and replay adapter are authored for MetricStitch,
  Apache-2.0.
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
