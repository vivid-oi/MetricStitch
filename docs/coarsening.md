# Exact explicit-histogram coarsening

`HistogramSample::coarsen(bounds)` merges buckets into a common coarser layout.
Every target bound must already occur in the source, in strictly increasing
finite order. Counts are summed with checked Int64 arithmetic, never interpolated
or split. Empty target bounds produce a single bucket containing the full count.
Identity, interval, count, sum and extrema are retained; arrays are detached.

Use this when producers export different detailed layouts that share a useful
coarse subset. For example, both `[1,2,4]` and `[0,2,4]` can target `[2]`. Requests
can then accumulate through the existing strict layout contract. A new bound
such as 1.5 is refused because the input does not say how to split its bucket.

`coarsen_otlp_histograms(request,bounds)` validates the supported Delta OTLP
profile and transforms only explicit-histogram bounds/counts. It preserves
metadata, point order, timestamps, temporality and other metric kinds. It is
bounded to 4M JSON code units and the capture adapter's metadata budget.

```sh
moon run --target wasm cli -- coarsen-to input.json bounds.json coarse.json
```

`bounds.json` contains a JSON number array. The output is a Delta request, not a
receipt; feed it to `apply-to` or `reorder-to`. No existing output is replaced.
Unsupported input or an unsafe target rejects the entire transformation.

For an already tracked typed histogram, explicitly call
`state.coarsen_histogram(series,bounds)` first. It migrates the cumulative total
and most-recent retry delta together, preserving the origin. Afterwards retry
the coarsened delta, not its old fine representation. Persist the new checkpoint
before adopting it. Other streams and the old state remain unchanged. The
ordinary accumulator still refuses unannounced layout changes.

Tests cover composed coarsening, Int64 limits, malformed bounds, ownership,
checkpoint recovery, retained metadata and continued accumulation after migration.
