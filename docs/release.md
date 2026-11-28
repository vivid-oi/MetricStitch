# Compatibility and release preparation

Current source version: **0.4.0**. This is a prepared source release candidate,
not a claim of Mooncakes publication, an attached GitHub release or a version tag.

## Contracts

- Public signatures are generated in `pkg.generated.mbti`. 0.2.0 adds APIs;
  `State::apply*`, `process_otlp`, `validate_otlp`, `Diagnostic` and
  `StitchError::Invalid(String)` retain their existing signatures and behavior.
  CLI `check` JSON adds a `code` field; consumers must allow that additive field.
- 0.4.0 adds disjoint state reattachment, explicit histogram coarsening, bounded
  NDJSON sessions, pending-gap reports and optional cumulative OTLP compaction.
  Existing strict processing, reorder output grouping and checkpoint formats
  retain their previous behavior. Replay sessions have a separate version 1
  envelope; their record ordinals are exact decimal strings. They authenticate
  neither input prefixes nor checkpoint/delivery correspondence. Compaction is
  explicit and optional, preserving point order and empty-container content.
- Core checkpoint versions 1 (integer), 2 (Double) and 3 (Histogram) remain
  readable. Version 4 adds exponential state; `BufferedPoint::Exponential` requires
  downstream exhaustive matches to be extended. Indexes are derived data and are not serialized. New buffer
  checkpoints use their own version 1 envelope and include every pending delta.
- Unknown fields/versions and unsupported data are refused, not silently
  discarded. Receipts/checkpoints are trusted local artifacts, not authenticated
  proofs. Retain original artifacts when upgrading.
- Before 1.0, changes to public contracts must be explicit in the changelog;
  breaking API or checkpoint changes require a new minor version and migration
  instructions. Patch versions are for compatible corrections. No compatibility
  with arbitrary future MoonBit toolchains is promised.

## Verified matrix

CI pins MoonBit 0.10.19+bee578715 (compiler and core). The pure core is tested on
Wasm, Wasm-GC, JS, and actual native Linux/macOS/Windows runs. The async CLI and
replay run on Wasm and the three native operating systems. The separate
Collector job pins core Collector 0.166.0, verifies the official asset SHA-256,
and asserts its real OTLP/HTTP receiver/file exporter results. This is one
Collector configuration, not universal backend compatibility.

## Prepare and inspect an archive

```sh
moon fmt --check
moon info
git diff --exit-code -- '*.mbti'
moon check --target all --deny-warn
moon package --list
moon run checks/package.mbtx
```

The final command packages `_build/publish/vivid-oi-metricstitch-0.4.0.zip`,
rejects leaked build/cache artifacts, checks licenses/interfaces, extracts it
into a fresh temporary workspace, runs its core tests, and builds an independent
consumer against the extracted library. It requires `tar` on Windows and `unzip`
on Unix. Optional arguments select a Moon executable and target:
`moon run checks/package.mbtx -- moon js`.
Temporary cleanup is confined to the originally resolved unique directory.

The archive excludes the repository-only consumer workspace and nested build
outputs. Packaging is repeatable from the same source, but byte-for-byte archive
reproducibility is not claimed. The CI package job uploads the verified zip,
identified by the workflow's source commit. Native jobs also test an extracted
archive and its consumer on all three OSes. A registry installation has not
been tested until an actual registry publication exists.

Publication is a separate operation: verify registry account/namespace and version
availability, review `moon publish --dry-run` with the intended toolchain, then
publish only with authorization. Verify the registry artifact by installing it
from a clean module. Never substitute a workspace dependency for that evidence.
