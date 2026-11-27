# Collector integration

This reproducible integration uses OpenTelemetry Collector **core 0.166.0**,
its OTLP/HTTP receiver and JSON file exporter. It does not require Docker,
an account, a backend or private infrastructure. Only loopback traffic is sent.
The Collector binary and `curl` must be installed separately from the library.
Official binaries: https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.166.0

From the repository root, with the tested MoonBit 0.10.19 toolchain:

```sh
moon update
moon run checks/collector.mbtx -- /absolute/path/to/otelcol
```

On Windows, pass the `.exe` paths; optional second and third arguments select
the `moon` and `curl` executables. Port **127.0.0.1:43180** must be free. The
checker creates a temporary configuration and output files, starts the pinned
Collector, waits for readiness, and always terminates its own child on exit.
It refuses a different Collector version. The input is the documented synthetic
adaptation in `examples/session.json`, not a production capture.

The checker converts the first request, persists its receipt, checks that a
retry suppresses both stateful points, refuses malformed input without publishing
a file, and processes the next request using the saved receipt. It sends the
two exported OTLP requests over HTTP. Both responses must be 200 without a
partial rejection. It then reads the Collector's JSON file output and asserts
both intervals: Counter 5 then 7.5; Histogram count 2 then 4; Gauge 10 then 11.
This checks a real receiver/exporter path, in addition to independent generated
JSON/Protobuf model checks. It does not establish exactly-once delivery, crash
durability, arbitrary Collector-version compatibility or compatibility with every
OTLP backend.

## Independent consumer module

`integration/consumer` has its own `moon.mod` and imports only the public
`vivid-oi/metricstitch` package. `integration/moon.work` resolves that dependency
to this checkout; no published registry package is needed.

```sh
moon -C integration run --target wasm consumer
moon -C integration run --target wasm-gc consumer
moon -C integration run --target js consumer
```

The consumer creates a counter, saves/restores a checkpoint, suppresses a retry
and asserts that the next cumulative value is 12. Native execution additionally
requires a working C toolchain. Workspace use verifies an external module
boundary; it does not claim that the module has been published to Mooncakes.
