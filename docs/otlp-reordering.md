# Reordering existing OTLP requests

`OtlpReorderBuffer` is an opt-in adapter around the typed `ReorderBuffer`.
It accepts the same strict OTLP/JSON profile as `process_otlp`: Int64/Double
monotonic Delta Sums, explicit and exponential Histograms, and Gauge samples.
It reuses the existing validator rather than accepting a second, looser format.

## Library workflow

Create `OtlpReorderBuffer::new(state, watermark=..., max_pending=...,
max_delay_ns=...)`. `push(request, watermark=...)` returns `OtlpReorderStep`:
the next `buffer`, a standard Cumulative OTLP `request`, and duplicate count.
`advance(watermark)` flushes without adding input. The typed buffer's watermark,
missing-predecessor, capacity, horizon and rollback rules apply unchanged.
The caller must establish the intended origin before advancing a new stream.

Pending points retain the complete validated resource/scope/schema/metric/point
envelope. Cumulative output changes only the aggregation values, interval origin
and temporality; it retains descriptors, attributes, flags and empty exemplars.
Ready points are emitted in deterministic end/series/start order, each with its
own resource/scope/metric group. Groups are not coalesced. Original empty
containers and empty metrics remain represented. A deferred nonempty group is
represented by its queued payload until its point is emitted, not as an empty
placeholder. Gauge samples pass through immediately in input order, including
retries; they are not reordered or deduplicated. Consumers may re-sort Gauge
observations downstream if their application needs event-time ordering.

Only adopt the returned buffer after accepting its output. `checkpoint()`
includes **all** pending payloads and their typed deltas. `restore()` revalidates
single-point envelopes and requires exact identity/value binding to typed pending
state. Inputs, checkpoints and outputs are detached JSON: mutating caller data
cannot change an older buffer. `state()` and `pending_count()` expose committed
progress. The old `process_otlp` entry point still rejects gaps and never buffers.

`OtlpReorderStep::receipt()` groups output and checkpoint into one artifact;
`decode_reorder_receipt` validates its structure. These remain trusted local
artifacts, not authenticated proofs or delivery acknowledgements. Binding checks
cover pending metadata and deltas, not arbitrary modifications of committed
totals or correspondence between historical output and state.

Requests, recovery checkpoints and generated complete receipts are bounded to
4M JSON code units and depth 64. Captured envelopes have a combined 4M budget to
prevent resource metadata being amplified once per point without a bound. A
transaction exceeding any budget is refused before returning a new buffer.
The typed buffer still limits batches/pending points to at most 4096, and
`max_pending` may be smaller. This is intended for short reorder windows.

## CLI workflow

```sh
moon run --target wasm cli -- reorder-to INPUT.json RECEIPT.json WATERMARK_NS
moon run --target wasm cli -- reorder-to NEXT.json NEXT_RECEIPT.json NEXT_WATERMARK_NS RECEIPT.json
moon run --target wasm cli -- inspect NEXT_RECEIPT.json
moon run --target wasm cli -- export NEXT_RECEIPT.json CUMULATIVE_OTLP.json
```

`WATERMARK_NS` is a positive decimal event-time boundary, not a wall-clock timer.
The first invocation bootstraps with watermark 1 ns, capacity 128 and a 60-second
pending horizon, then advances to the supplied watermark. Supply a watermark
before a future point's end to retain it. Library callers can configure other
limits. Subsequent invocations restore all configuration and queued payloads
from the previous receipt. To advance without input, use a file containing
`{"resourceMetrics":[]}`. First emission establishes each new series's origin;
the tool cannot infer an earlier missing interval.

Files are regular UTF-8, at most 4 MB. A new receipt is published exclusively
with the existing write/sync/no-replace mechanism. Failure exits 2 and publishes
nothing; existing inputs/receipts are never overwritten. Successful publication
has empty stdout. Export and inspect recognize both strict and reorder receipts.

## Reproduce the complete file workflow

```sh
moon run checks/reorder.mbtx -- moon wasm
```

The checker reads the checked-in session adapted from the official OTLP example,
derives a third interval, and submits order 3,1,2. It restores receipt files,
asserts refusal of a premature watermark without output, fills the gap, verifies
Counter totals 7.5/11 and Histogram counts 4/6, checks metadata and retry behavior,
then independently validates the exported JSON and Protobuf. Gauge follows
arrival order as documented. CI also runs the workflow on each native OS.

The Collector differential job additionally sends three ordered Delta requests
to its own processor and order 3,1,2 to the adapter. It compares all 30 complete
point envelopes after normalizing grouping/arrival order and empty exponential
edge padding. Values, timestamps, types, temporality and metadata remain part of
the comparison. This covers all four stateful kinds plus Gauge through a real
receiver/exporter path; it is not universal OTLP backend compatibility.
