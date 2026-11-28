# Changelog

## Unreleased

- Diagnose every queued missing interval with deterministic read-only reports,
  unknown-origin markers, dry-run advance results and original OTLP context;
  `explain-reorder` makes the re-fetch/repair workflow available from saved receipts.

- Bounded UTF-8 NDJSON framing, immutable replay sessions and validated records;
  stream replay/export with continuations and atomic whole-output publication.

- Exact explicit-histogram coarsening, typed state migration and `coarsen-to`
  OTLP files; non-subset layouts are refused without interpolation or data loss.

- Reattach disjoint state archives/shards with explicit conflict/capacity checks
  through `State::merge_disjoint` and atomic `merge-state` file publication.

## 0.3.0 — source release candidate, 2026-11-27

- Independent shared-profile differential checks against Collector Contrib 0.166.0.
- Exponential histogram accumulation, scale alignment and bounded downscaling,
  OTLP conversion/export, checkpoint version 4, lifecycle and typed reorder support.
- `BufferedPoint::Exponential` is a new enum case; exhaustive matches must handle
  it. Zero-threshold changes are explicitly unsupported and rejected.
- Opt-in OTLP reordering retains full pending envelopes, validates typed payload
  bindings, supports recoverable `reorder-to` receipts and existing export/inspect,
  and compares reordered output against ordered Collector point envelopes.

## 0.2.0 — source release candidate, 2026-11-27

- Added a pinned real Collector receiver/file-exporter integration check and a
  separate module consuming only public APIs.
- Added `diagnose_otlp`, `DiagnosticDetail` and stable `IssueCode` categories.
  The CLI check report adds `diagnostic.code`; legacy diagnostics/errors remain.
- Indexed series and added detached per-request transactions. Checkpoint JSON
  versions and sorted output are unchanged. Added scale tests and a benchmark.
- Added optional bounded `ReorderBuffer` for Int64, Double and explicit Histogram
  points, explicit watermarks, typed errors, rollback and pending-state recovery.
- Added Chinese quick start, compatibility policy and archive consumption checks.

No Mooncakes publication or GitHub version tag is implied by this entry.

## 0.1.0 — initial source baseline

Strict bounded delta accumulation, OTLP/JSON conversion, typed attributes,
explicit histograms and Gauge pass-through; atomic sequence replay; versioned
checkpoints, file receipts, inspection/export and explicit state archival.
