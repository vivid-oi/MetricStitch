# Reattaching an archive or disjoint shard

`State::merge_disjoint(other)` reconstructs one usable state from independent
sets of identities. It preserves Int64/Double/explicit/exponential records,
cumulative origins and last-delta retry information. It never adds cumulative
totals from overlapping streams. Even identical overlapping records are refused;
choose the authoritative snapshot explicitly rather than merging it twice.

The destination state's configured series capacity applies to the union. The
other state's capacity is not imported. Errors leave both states reusable. The
result has private rebuilt indexes and deterministic sorted checkpoints. No
checkpoint version change is needed; version selection follows its metric kinds.

Archive workflow: partition with `partition_before`, persist both outputs, route
late data to its archived state, then merge the updated archive into retained
before adopting the returned state. A series already recreated in retained
causes a conflict, so an old cumulative origin is never silently combined with
a new one. This is a single-writer state handoff, not distributed conflict
resolution or concurrent-writer coordination.

```sh
moon run --target wasm cli -- merge-state retained.json archived.json joined.json
```

The inputs are state checkpoints, not receipt envelopes. Output is a new
checkpoint file, at most 4 MB, published with replacement disabled. Existing
inputs/output stay intact on failure. For an empty destination with a different
capacity, library callers can create `State::new(max_series=...)` and merge into
it. Unit tests rejoin a four-kind archive, compare serialized checkpoints,
resume deltas/retries, and verify collisions, exact capacity and rollback.
