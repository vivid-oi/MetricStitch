# MetricStitch

A portable, bounded delta-to-cumulative processing library for MoonBit.
Its consumers are telemetry gateways and offline OTLP replay tools.

The core accumulates nonnegative Int64 and finite Double deltas with explicit interval
continuity, last-point retry detection, checked overflow and atomic batches.
State is immutable. Keep the returned state only after accepting the output.
Older retries, gaps and overlaps raise `StitchError` and preserve the old state.
New producer instances must have different series identities.

Run `moon run examples/counter` to accumulate 7 and 5 into 12.
Run `moon test --target wasm` for the public contract tests.

Direct library callers provide series keys. `State::checkpoint` returns versioned
JSON with exact decimal strings and sorted series. `State::restore` validates
budgets, duplicate series, intervals and cumulative consistency before accepting
state. Persistence and authenticity are the caller's responsibility. Unknown
checkpoint fields and versions are rejected. Restored last-point retries remain
idempotent.

## OTLP file workflow

`process_otlp(state, request)` accepts an OTLP/JSON ExportMetricsServiceRequest
and returns a new state, cumulative request and duplicate count. The input JSON
and original state remain intact on failure. `parse_input(text)` rejects duplicate
decoded JSON object keys and limits nesting to 64 and text to 4M code units.

The supported profile is DELTA monotonic Sum with exactly one nonnegative `asInt`
decimal string or finite nonnegative `asDouble` number and positive strictly
increasing nanosecond timestamps. Double accumulation uses ordered IEEE-754
addition with overflow rejection, so rounding follows Double arithmetic.
`State::apply_doubles` exposes the typed floating-point entry point. A series
cannot switch between Int64 and Double. The series budget is shared by both.
Pure-integer checkpoints retain version 1, while states with floating-point
series use version 2. Both versions can be restored. Attributes support
strings, booleans, signed Int64 decimal strings, finite numeric doubles, base64
bytes, arrays and key-value lists. Each attribute set has a 4096-value budget and
16-level nesting limit. Attributes and nested key-value lists require unique keys.
Identity preserves value kinds, canonicalizes integer/base64 representations and
sorts key-value lists while retaining array order. Outgoing metadata preserves
the original representation. Existing string-only series keys remain compatible.
Resource and scope identity includes
their attributes, scope name/version, both schema URLs, metric name/unit/description
and point attributes. Attribute order does not affect identity. A description
change deliberately creates a separate stream in this strict initial profile.
Optional zero flags, empty exemplars and zero dropped-attribute counts are accepted.
Other fields, metric kinds and values are refused with diagnostics. There is no
numeric coercion or silent omission of unsupported data.

```sh
moon update
moon run checks/replay.mbtx -- moon wasm
moon run --target wasm cli -- input.json
moon run --target wasm cli -- next.json checkpoint.json
```

Success emits one JSON receipt containing `request`, `checkpoint` and `duplicates`.
The consumer extracts `request` for its exporter and persists `checkpoint` for the
next call. Persisting the whole receipt as one artifact keeps the output and its
state together. This CLI reads regular UTF-8 files up to 4 MB, emits at most 4 MB,
and exits 2 on failure with diagnostics on stderr and no result on stdout.
Callers own file publication, delivery acknowledgement and single-writer ordering.

Three intended uses are receiving integer deltas in a gateway, resuming a local
agent after a checkpoint, and reproducing a faulty telemetry batch offline.
The replay demonstrates all three using the official OTLP example. It first
verifies refusal of the unmodified example's unsupported types, then derives an
Int64-only two-interval counter from its real protocol structure, retains its
resource/scope/attributes, accumulates 5 and 7 into 12 across a checkpoint and
checks retry suppression and error recovery. The intervals and integer values
are demonstration edits, not production telemetry. See SOURCES.md.

The core supports wasm, wasm-gc, js and native. The async CLI supports wasm and
native. CI runs core tests on the portable targets and native Linux/macOS/Windows,
and executes the documented replay on Wasm and each native OS.

## Roadmap

Explicit and exponential histograms,
out-of-order buffering, network receivers and multi-writer coordination are
planned capabilities. The current profile requires contiguous intervals. It
remembers only the most recent delta per series and does not offer unbounded
deduplication or an exactly-once delivery guarantee.

The semantic reference is the OpenTelemetry metrics data model
<https://opentelemetry.io/docs/specs/otel/metrics/data-model/>.
The state-processing boundary complements instrumentation SDKs and exporters.
Implementation and tests are authored for this project. The Apache-2.0 license
text is shared with the owner's Apache-2.0 projects. The official OTLP example
is included with its license. Processing code is authored for this project.
