# Bounded event-time reordering

`ReorderBuffer` is an optional typed layer around the strict accumulator.
It accepts `BufferedPoint::Counter(Sample)`, `DoubleCounter(DoubleSample)` and
`Histogram(HistogramSample)` and `Exponential(ExponentialSample)`. It is not an OTLP receiver or an automatic repair
of arbitrary request ordering. Gauges do not require this accumulation layer.

1. Construct it from a committed `State`, a positive initial `watermark`,
   `max_pending` (1..4096, default 128), and positive `max_delay_ns`.
2. Call `push(points, watermark=...)`. Up to 4096 supplied deltas are staged;
   points ending at or before the new watermark are processed in deterministic
   end-time, series, start-time order. Returned points are **cumulative**.
3. Keep the returned buffer only after accepting its output. Both the prior
   buffer and its committed state remain usable. `advance(watermark)` adds no
   points. A missing predecessor rejects the entire call; fill the gap using
   the previous buffer and retry. No point is evicted or interpolated.
4. Persist `checkpoint()` (which includes *every pending delta*) and restore
   with `ReorderBuffer::restore`. The separate state checkpoint versions remain
   unchanged. Inspect committed state with `state()` and queue size with
   `pending_count()`.

The watermark is a caller assertion: future new data must not end at or before
it. It is not wall-clock time and is not automatically derived from arrivals.
`max_delay_ns` bounds how far a retained point's end may be ahead of the new
watermark. Equality is accepted. This parameter does **not** guarantee a maximum
real elapsed holding time. Callers decide when it is safe to advance.
The initial watermark must not precede committed ends. A new series begins at
its earliest emitted point; the library cannot infer a missing earlier origin.
Supply all intended predecessors before advancing its watermark.

Exact duplicates in the queue and exact retries of a committed last point are
counted without reaccumulation. Conflicting or overlapping points and kind/layout
changes are rejected. Older committed points are not an unbounded retry ledger.
After flushing, retained points must fit the capacity and horizon. A batch may
temporarily exceed capacity if the same transaction drains it; if a bound or
validation check fails, neither state nor watermark advances. Errors are typed:
`LatePoint`, `BufferFull`, `WindowExceeded`, `ReorderConflict`, `MissingInterval`
and `ReorderInvalid`. Overflow and malformed values are never silently dropped.

Histogram arrays are copied on input and output. Checkpoint restore refuses
unknown fields/versions, duplicate pending points and points already closed by
its watermark. Capacity checks and pairwise conflict detection are bounded by
4096 pending points and 4096 supplied points; this layer is intended for small
reorder windows, not large historical sorting jobs or multi-writer coordination.

```sh
moon run --target wasm examples/reorder
```

The executable supplies intervals in order 3,1,2, restores a checkpoint while
interval 3 is pending, verifies that premature advancement fails, fills interval
2, and asserts cumulative values 5,12,15. CI also runs it on Wasm-GC, JS and each
native OS. Strict `State::apply*` and `process_otlp` behavior is unchanged.
