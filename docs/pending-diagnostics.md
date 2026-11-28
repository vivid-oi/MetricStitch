# Diagnose and repair queued gaps

When a later interval arrives first, `MissingInterval` refuses publication.
`explain-reorder` reads the saved receipt without advancing its watermark:

```sh
moon run cli -- explain-reorder first-emitted.json 1544712660900000000
```

In the documented 3,1,2 workflow (`checks/reorder.mbtx`) this reports both
Counter and Histogram gaps `[1544712660300000000,1544712660600000000)`, with
the following queued point's original `nextRequest`. Its metric, resource,
scope and attributes identify what to re-fetch. Supply the missing second
request to `reorder-to` with the same saved receipt, then advance again.
The diagnostic does not create files or change committed/pending data.

`ReorderBuffer.pending_report(target)` returns `PendingReport`: current and
requested watermark, pending/ready counts, capacity, configured delay, earliest
and latest queued ends, every observed missing interval, and unanchored series.
All timestamps render as exact decimal strings in `to_json()`. Gaps follow the
same deterministic end/series/start order as the queue. `blocks_target` means
the following point is due at this target; gaps beyond the target are listed
too, so an operator can request multiple missing intervals in one pass.

An unanchored series has no committed predecessor. Its earliest queued start
is the possible origin; this report cannot discover events absent from both
the queue and checkpoint. It never invents a missing prefix from the global
watermark. Callers still establish origins before closing event-time windows.

`canAdvance` is based on a dry run, including arithmetic overflow and profile
validation; an empty gap list alone is insufficient. The OTLP adapter also dry
runs output/checkpoint budget validation. `advanceError` is a display message,
not a machine-stable error-code API. Targets before the current watermark are
rejected. Success applies to this exact buffer/target, not future inputs or
delivery acknowledgement. Reporting does not replace `advance` error handling.

`OtlpReorderBuffer.pending_report(target)` returns owned JSON with the same
fields and detached `nextRequest` context for each gap. It enforces the usual
4M JSON code-unit budget and can reject an oversized enriched report. No
external service, clock or private infrastructure is needed to run the example:

```sh
moon run checks/reorder.mbtx -- moon wasm
```

Unit tests cover multiple gaps, interleaved identities, all four accumulator
kinds, unknown origins, future gaps, overflow without gaps, determinism,
backwards targets, immutable diagnostics, and recovery by inserting missing data.
