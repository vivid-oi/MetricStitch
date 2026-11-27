# Exponential histograms

`State::apply_exponentials(Array[ExponentialSample])` and OTLP
`exponentialHistogram` accept Delta populations over contiguous intervals. The
same transaction, last-delta retry and explicit error rules as other kinds apply.
`ExponentialBuckets` contains a signed Int32 offset and dense Int64 counts;
positive and negative sides describe absolute magnitudes separately.

Supported profile:

- Scale -10..20, at most 1024 incoming buckets per side and signed Int32 indexes.
- Exact nonnegative Int64 population, zero count and per-bucket counts. Their
  checked total must match `count`; count overflow is rejected.
- Finite nonnegative zero threshold, constant within a stream. A threshold change
  is refused explicitly: this version does not infer how to move populations
  across a wider zero region.
- Optional finite nonnegative sum, with unchanged availability. Negative-side
  populations require absent sum, following the protocol's sum recommendation.
  Min/max are paired, finite, ordered and absent for empty populations. Nonempty
  intervals must agree on their availability; empty intervals retain extrema.
- Nonzero flags, nonempty exemplars and unknown fields are refused. Input metadata
  and attributes survive supported conversion; no unsupported data is dropped.

## Alignment and bounded merging

Two scales align to the lower scale. Bucket index mapping uses exact signed
integer floor division by `2^(source_scale-target_scale)`, including negative
indexes; no logarithm or floating-point boundary reconstruction is involved.
If either merged dense span would exceed 1024 bins, the common scale is lowered
further until both fit. Scale never falls below -10. If no supported scale can
fit, the operation fails without publishing state. This lowers resolution through
perfect subsetting; it never splits bins or drops a nonzero count.

Empty edges are canonicalized in cumulative output (empty sides use offset 0).
Original last deltas are saved without that normalization so exact retries still
work after restoration. Input/output arrays are copied. Version 4 checkpoints
contain exponential state and still read versions 1/2/3; states without
exponentials retain their previous checkpoint version/output. Restore validates
canonical totals and their bucket-wise containment of the downscaled last delta.

`BufferedPoint::Exponential` extends the typed reordering layer. It uses the same
capacity, watermark and recovery contract as other points. It is a new public
enum case in source version 0.3.0: downstream exhaustive matches must handle it.

```sh
moon run --target wasm examples/exponential
moon run checks/replay.mbtx -- moon wasm
```

The example adapts the pinned official OTLP exponential population (two positive
values plus one zero) into two intervals with scales 0/1. It restores state and
asserts count 6, zero count 2, positive count 4, sum 20 and retry suppression.
The replay adapts only the official example's times, persists/restores a version
4 receipt, exports the result, and runs independent JSON/Protobuf checks. These
are synthetic adaptations, not production measurements.

The differential test also compares positive/negative/zero populations through
scale changes 2→1→0 against pinned Collector Contrib. It stays below its 160-bin
policy threshold; our 1024-bin automatic-limit behavior has independent contract
tests. Comparison trims only zero edge padding, whose allocation differs between
implementations, while preserving and comparing all populated indexes/counts.

Behavioral references, not copied processing code:
https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponentialhistogram
https://github.com/open-telemetry/opentelemetry-proto/blob/d31f7acf9d461fd0601077de516ac1eb7051422f/opentelemetry/proto/metrics/v1/metrics.proto
