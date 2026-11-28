# Compact repeated cumulative OTLP envelopes

The reorder adapter deliberately emits a group per released point, retaining
the original metadata. An offline exporter can remove adjacent repeated headers
before persisting or sending that output:

```sh
moon run cli -- export recovered-receipt.json cumulative.json
moon run cli -- compact-to cumulative.json compacted.json
moon run checks/protocol.mbtx -- compacted.json
```

Use new destination paths. `compact-to` validates the complete supported
cumulative OTLP profile before opening a publication temporary file. It closes,
syncs and publishes only successful output and refuses an existing destination.
Malformed data, unknown fields, Delta temporality, unsupported exemplars/flags
and budget violations produce errors; none are dropped or converted implicitly.

The portable API is `compact_otlp(request: Json) -> Json raise StitchError`.
Input/output have the existing 4M JSON code-unit parser budget; CLI UTF-8 files
also have a 4 MB byte limit. Returned data is owned and input is never mutated.
This is optional post-processing, so strict accumulation and reorder outputs
retain their previous behavior. It does not repair an oversized receipt that
the reorder adapter already rejected.

The algorithm walks the hierarchy in original order. Adjacent resource groups
merge only when headers excluding `scopeMetrics` render identically. The same
rule applies to scope headers excluding `metrics`, and metric headers excluding
their kind's `dataPoints`. At a matching boundary, child sequences are appended
and only the adjacent boundary is reconsidered. Every data point is copied
through in the same traversal order, including repeated points; no values are
summed, deduplicated, sorted or downsampled. All five supported value profiles
(Int64 Sum, Double Sum, explicit/exponential Histogram and Gauge) are supported.

Equality is intentionally conservative: different schema URLs, descriptions,
units, omitted versus explicit metadata, attribute order or rendered header
representations can prevent merging. Equivalent normalized stream identities
alone do not justify discarding those distinctions. Empty resources, scopes
and metric bodies remain barriers at their own level and remain in their
original position. Original JSON whitespace/key order is not a preservation
contract; exact point values, metadata and container content are.

The transformation is deterministic and idempotent for the same serialized
input. Unit tests flatten complete point envelopes and empty-container events
to verify conservation and order, ownership, barriers, malformed/oversized
input and recovery after refusal. The offline `checks/reorder.mbtx` verifies
the file workflow and independent generated JSON/Protobuf model round trips.
`checks/differential.mbtx` additionally sends the compacted reorder output through
Collector Contrib 0.166.0 and compares its complete point envelopes against
ordered reference accumulation. These checks establish the stated profile,
not arbitrary OTLP compatibility or a general performance advantage.
