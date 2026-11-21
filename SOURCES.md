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
* OpenTelemetry metrics data model is the behavioral reference, not copied code.
  https://opentelemetry.io/docs/specs/otel/metrics/data-model/
* `moonbitlang/async` 0.22.5 provides CLI filesystem/process/runtime adapters,
  Apache-2.0. https://github.com/moonbitlang/async
* The root Apache-2.0 license text comes from the owner's MoonPOMerge repository.
* `cli/publish.mbt` adapts the Apache-2.0 temporary-file publication pattern from
  https://github.com/vivid-oi/MoonPOMerge/blob/974bf668b480334dd2b38b1eaa6744faf9b26471/cmd/main/driver.mbt
  That source credits FontPin and MBTRelMask.
