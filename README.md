# MetricStitch

A portable, bounded delta-to-cumulative processing library for MoonBit.
Its consumers are telemetry gateways and offline OTLP replay tools.

The initial core accumulates nonnegative Int64 deltas with explicit interval
continuity, last-point retry detection, checked overflow and atomic batches.
State is immutable. Keep the returned state only after accepting the output.
Older retries, gaps and overlaps raise `StitchError` and preserve the old state.
New producer instances must have different series identities.

Run `moon run examples/counter` to accumulate 7 and 5 into 12.
Run `moon test --target wasm` for the public contract tests.

Direct library callers provide series keys. A standard OTLP adapter and durable
checkpoints are planned next. Double sums, histograms, network receivers and
multi-writer coordination are planned capabilities.

The semantic reference is the OpenTelemetry metrics data model
<https://opentelemetry.io/docs/specs/otel/metrics/data-model/>.
The state-processing boundary complements instrumentation SDKs and exporters.
Implementation and tests are authored for this project. The Apache-2.0 license
text is shared with the owner's Apache-2.0 projects. No upstream processing
code or test fixtures are copied in this initial core.
