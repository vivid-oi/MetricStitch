# Independent accumulation comparison

From the repository root, run:

```sh
moon run checks/differential.mbtx -- /absolute/path/to/otelcol-contrib
```

Use official **Collector Contrib 0.166.0**, not the core distribution. Optional
arguments select the Moon and curl binaries. Ports 127.0.0.1:43181 and :43182
must be free. No private infrastructure or external telemetry destination is
used. The checker starts and terminates its own Collector and removes its own
temporary files.

The reference pipeline receives the original Delta requests and runs the
official `delta_to_cumulative` processor. The candidate pipeline receives
MetricStitch's already-converted Cumulative requests and runs no converter.
Both use the same Collector file exporter. The checker decodes both outputs
using independent generated OTLP models and compares all typed fields, including
timestamps, metadata, attributes, sums, counts and buckets. Protocol defaults
are normalized by decoding, rather than by ignoring fields in a JSON comparison.

The generated, reproducible fixture has 32 contiguous intervals, two attribute
identities per metric, Int64 values above 2^53, exact quarter-valued Doubles,
explicit Histograms with changing bucket populations/extrema, and signed Gauge
values. Exponential histograms include positive/negative/zero populations and
scale changes 2→1→0. All 320 points are compared. Empty exponential edge padding
is trimmed to compare identical bucket-index populations; no populated bucket,
count or other field is ignored. MetricStitch checkpoints are restored
between every interval. These are synthetic test cases, not production captures.

## Common semantics, not identical policies

The shared-profile comparison deliberately uses valid consecutive intervals,
fixed metric identities/layouts and counts fitting Int64. It is not a claim
that both processors have identical error, retry or retention behavior:

- MetricStitch refuses gaps, overlaps, kind/layout switches and overflow with
  atomic failure. A malformed later point leaves the original state usable.
- The pinned upstream processor filters failing points, resets explicit
  Histograms when boundaries change, and can expire streams or drop new streams
  at a configured limit. Its implementation uses native integer addition.
- MetricStitch's last-point retry suppression and explicit archive/reorder
  policies have their own contract tests. Collector is an independent reference
  for the shared accumulation profile, not an oracle for all those policies.

The pinned sources are Apache-2.0:
https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.166.0/processor/deltatocumulativeprocessor
https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.166.0/processor/deltatocumulativeprocessor/internal/data/add.go

No upstream processing code or test case is copied. The CI binary is checked
against its official GitHub release asset SHA-256 in `checks/contrib.sha256`.

An additional adapter comparison sends three requests in ordered form to the
reference and arrival order 3,1,2 to the file-based OTLP reorder workflow. All
30 complete point envelopes are compared after normalizing grouping and arrival
order. No point value or metadata is excluded. This checks the typed buffer's
OTLP binding, checkpoint recovery, optional adjacent-header compaction and export
together. Before sending, the checker also compares exact ordered point envelopes
before/after compaction, without normalizing away metadata differences; see
[OTLP reordering](otlp-reordering.md).
