# Changelog

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
