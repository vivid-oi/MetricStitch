# MetricStitch

[中文快速入门](README.zh-CN.md) · [Changes](CHANGELOG.md) · [Compatibility and packaging](docs/release.md)

A portable, bounded delta-to-cumulative processing library for MoonBit.
Its consumers are telemetry gateways and offline OTLP replay tools.

The core accumulates nonnegative Int64 and finite Double deltas with explicit interval
continuity, last-point retry detection, checked overflow and atomic batches.
State is immutable. Keep the returned state only after accepting the output.
Older retries, gaps and overlaps raise `StitchError` and preserve the old state.
New producer instances must have different series identities.

Run `moon run examples/counter` to accumulate 7 and 5 into 12.
Run `moon test --target wasm` for the public contract tests.

## Complete local example

The checked-in session adapts the pinned official OTLP example into two
contiguous intervals. It includes a Double counter, Gauge and explicit histogram.
Use new destination filenames for the following commands.

```sh
moon update
moon run --target wasm cli -- replay-to examples/session.json session-receipt.json
moon run --target wasm cli -- inspect session-receipt.json
moon run --target wasm cli -- export session-receipt.json session-otlp.json
moon run checks/protocol.mbtx -- session-otlp.json
```

The second interval has cumulative counter 7.5, histogram population 4 and Gauge
11. Inspection reports two active series because Gauge has no cumulative state.
The exported file is a standard OTLP request suitable for an existing exporter
or receiver. The last command independently decodes it with the community
OpenTelemetry generated model and verifies JSON and Protobuf round trips.
This is protocol-model interoperability validation. A separate
[Collector integration](docs/collector.md) checks a real pinned receiver and
file exporter, plus a separate consumer module. `checks/replay.mbtx` exercises these same commands in
a temporary directory on Wasm and all three native CI operating systems.
An [independent accumulation comparison](docs/differential.md) compares the
shared profile against Collector Contrib's own delta-to-cumulative processor.

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
moon run --target wasm cli -- apply-to input.json first.json
moon run --target wasm cli -- apply-to next.json second.json first.json
```

Success emits one JSON receipt containing `request`, `checkpoint` and `duplicates`.
The consumer extracts `request` for its exporter and persists `checkpoint` for the
next call. Persisting the whole receipt as one artifact keeps the output and its
state together. This CLI reads regular UTF-8 files up to 4 MB, emits at most 4 MB,
and exits 2 on failure with diagnostics on stderr and no result on stdout.
`apply-to` writes the complete receipt to a new destination. It validates all
input, writes and syncs a sibling temporary file, closes it and publishes with
replacement disabled. Existing destinations, including input or previous-receipt
paths, are refused. Success has empty stdout. Failed publication cleans up its
temporary file. The optional previous receipt supplies its validated checkpoint
directly, so file-based callers can resume without extracting JSON fields.
Receipt files are trusted local state, with structural validation rather than
authentication. Callers own delivery acknowledgement and single-writer ordering.
Directory crash durability and hostile concurrent filesystem mutation are outside
this publication contract.

`OtlpStep::receipt()` produces the receipt envelope. `decode_receipt(value)`
validates the envelope, checkpoint and supported Cumulative request profile.
It accepts historical points from a multi-request replay without accumulating
them a second time. Validation does not prove a relationship between a modified
checkpoint and its output, and does not establish delivery acknowledgement.
`export RECEIPT.json OUTPUT.json` validates a receipt and publishes only its OTLP
request to a new file, retaining the full receipt as the recovery artifact.
`inspect RECEIPT.json` validates and reports state capacity and duplicate count.
File-based resumption uses the same receipt validation as inspection and export.

Three intended uses are receiving integer deltas in a gateway, resuming a local
agent after a checkpoint, and reproducing a faulty telemetry batch offline.
The replay demonstrates all three using the official OTLP example. It first
verifies refusal of the unmodified example's unsupported types, then derives an
Int64-only two-interval counter from its real protocol structure, retains its
resource/scope/attributes, accumulates 5 and 7 into 12 across a checkpoint and
checks retry suppression, error recovery, whole-receipt resumption and refusal
to overwrite existing files. The intervals and integer values
are demonstration edits, not production telemetry. See SOURCES.md.

The core supports wasm, wasm-gc, js and native. The async CLI supports wasm and
native. CI runs core tests on the portable targets and native Linux/macOS/Windows,
and executes the documented replay on Wasm and each native OS.
See [scale and reproducible benchmarks](docs/performance.md) for the private
series index, transaction copying costs and measured workload limitations.

## Explicit histograms

Explicit-bucket Delta histograms are supported by `State::apply_histograms` and
the OTLP workflow. Counts and population are nonnegative Int64 values, with
checked addition, at most 1024 finite increasing bounds, and exactly bounds+1
buckets. Population must equal the bucket total. Arrays are copied at both API
boundaries. Sum is optional and uses finite Double addition. Min/max are supplied
together or omitted together, and empty populations omit extrema. Layout and sum
availability must remain constant. Nonempty intervals must agree on extrema
availability. Unsupported changes are refused. Histogram states use checkpoint
version 3. Versions 1 and 2 remain readable and retain their existing output.
The replay also exercises the pinned official histogram across two intervals
and a saved receipt. Its times are edited to form contiguous positive intervals.

## Validation

Mixed requests may include Gauge metrics. Their finite signed Double or signed
Int64 samples are validated and passed through unchanged. Gauge timestamps must
be positive, and optional start times must not exceed the end. Gauge values do
not accumulate, allocate series state or participate in retry suppression.
Nonzero flags and nonempty exemplars are refused. A bad Gauge rejects the whole
request, including earlier Sum or Histogram conversions. The replay verifies
the official Counter/Gauge/Histogram examples together after adapting their times.

`validate_otlp(state, request)` runs the complete conversion checks and returns
the first `Diagnostic` or None. Its RFC 6901 pointer locates the nearest resource,
scope, metric or data-point container, including array indices. `process_otlp`
retains `StitchError::Invalid` and prefixes its message with the same location.
Run `moon run --target wasm cli -- check input.json checkpoint.json` as a read-only
CI gate. Valid input prints a JSON report and exits 0. Semantic errors print the
diagnostic report and exit 2. JSON syntax and file errors use stderr and exit 2.
The command checks the supplied state without publishing a converted receipt.

`diagnose_otlp(state, request)` adds a stable `IssueCode` without changing the
legacy diagnostic or `StitchError::Invalid(String)` API. The CLI `check` report
includes `diagnostic.code`: `invalid_input`, `unsupported_data`,
`noncontiguous_interval`, `conflicting_retry`, `series_limit`, `numeric_overflow`
or `kind_changed`. Codes are assigned by validation, not by matching messages.
Malformed numbers and shapes are invalid input; a valid but overflowing cumulative
addition is numeric overflow. A retry with the last interval but different content
is conflicting; older points, gaps and overlaps are noncontiguous. Messages can
evolve; use the code and pointer for programmatic handling.

## Recorded batch sequences

`process_sequence(state, requests)` converts up to 1024 standard OTLP requests in
order as one transaction. The result is a standard request retaining all emitted
ResourceMetrics groups in order, a final checkpoint and total duplicate count.
It does not coalesce groups. Failures identify `/requests/N` followed by the
indexed input location. No partial state is returned.

For offline recordings, write `{"requests":[REQUEST_1,REQUEST_2]}` to sequence.json
and run `moon run --target wasm cli -- replay-to sequence.json receipt.json`.
An optional last argument accepts a previous receipt. The same input/output
budgets, exclusive file publication and error cleanup as apply-to are used.
The documented replay compares this workflow with sequential execution, including
retries, restored state and a failed final request that publishes no receipt.

## State lifecycle

`State::summary()` reports capacity, kind counts and oldest/newest last-point end
times as exact decimal strings. `State::partition_before(cutoff)` explicitly
partitions state at last.end < cutoff. Its `retained` and `archived` states keep
the original capacity and can both be checkpointed and restored. The original
state remains reusable. Persist the archive before adopting retained. Delayed
points can continue through archived. Reintroducing an archived series into
retained begins a new cumulative origin and loses its previous retry window.
This operation is explicit, with no automatic eviction or system-clock access.
Run `moon run examples/archive` to exercise archival and retry recovery.

## Roadmap

The optional [bounded reordering layer](docs/reordering.md) accepts typed Int64,
Double and Histogram deltas with explicit watermarks, recoverable pending state,
strict limits and no automatic eviction. Run `moon run examples/reorder`.
The OTLP request API remains strict and does not reorder requests automatically.

Exponential histograms, network receivers and multi-writer coordination are
planned capabilities. The current profile requires contiguous intervals. It
remembers only the most recent delta per series and does not offer unbounded
deduplication or an exactly-once delivery guarantee.

The semantic reference is the OpenTelemetry metrics data model
<https://opentelemetry.io/docs/specs/otel/metrics/data-model/>.
The state-processing boundary complements instrumentation SDKs and exporters.
Implementation and tests are authored for this project. The Apache-2.0 license
text is shared with the owner's Apache-2.0 projects. The official OTLP example
is included with its license. Processing code is authored for this project.
