# Scale and performance

Run `moon run --release --target wasm benchmarks` (also supports wasm-gc, js
and native). The benchmark inserts distinct Int64 series, updates every series,
then retries every point. Each case has one warm-up and five measured executions;
the output is the median **microseconds** for each whole batch. Input construction
and checkpoint serialization are outside the timed region. Assertions keep the
result observable. This is a diagnostic workload, not a throughput guarantee.

Illustrative local results on Windows x64, MoonBit 0.10.19+bee578715,
release Wasm, 2026-11-27. Baseline is commit 7c96597 with the same benchmark;
the indexed implementation was measured in the same checkout and toolchain.
Timing varies with runtime warm-up, GC, machine load and platform.

| Series / batch | Baseline insert / update / retry (µs) | Indexed insert / update / retry (µs) |
|---|---:|---:|
| 100 | 74.5 / 78.6 / 62.7 | 64.5 / 49.4 / 26.8 |
| 1,000 | 1,093.8 / 1,125.7 / 1,065.8 | 464.6 / 176.4 / 99.6 |
| 10,000 | 114,765.6 / 120,165.6 / 122,202.4 | 1,510.8 / 1,133.7 / 549.5 |

The state now has a private series-to-kind/index lookup. A typed batch copies
its touched record array and lookup once, then performs indexed lookups. An OTLP
request detaches all record arrays and the lookup once, then updates only that
private transaction. Validation or conversion failure publishes none of it.
Expected lookup cost is constant on ordinary hash distributions, not a worst-case
bound against adversarial collisions. Copying remains proportional to existing
state; many tiny requests against a large state still incur that cost. This is
not a persistent-map implementation and no memory reduction is claimed.

The checkpoint contains no indexes. Versions 1/2/3, sorted series order and exact
decimal numbers are unchanged. Restore and archive partitioning rebuild private
indexes. Tests cover 10,000 series, input-order-independent checkpoints, restore,
retry, late failure rollback, and retained old states. Existing mixed numeric and
histogram tests cover kind conflicts and detached bucket arrays. Benchmarks are
not CI pass/fail thresholds; correctness tests are.
