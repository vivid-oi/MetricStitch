# Bounded-memory NDJSON replay

Collector JSON file recordings use newline-delimited OTLP requests. `stream-to`
processes one supported Delta request per physical record rather than loading
the whole recording. Both input and output may exceed the ordinary CLI's 4 MB
whole-file limit. Per-record and state/series limits still apply.

```sh
moon run --target wasm cli -- stream-to recording.ndjson receipts.ndjson
moon run --target wasm cli -- stream-export receipts.ndjson cumulative.ndjson
```

Replay output has one JSON receipt per input record: `ordinal` (one-based exact
decimal string), `session` checkpoint, cumulative `request`, and duplicate count.
`stream-export` validates receipts and their increasing contiguous ordinals, then
writes standard OTLP requests only. It accepts any positive first ordinal so a
continuation file can be exported. Existing export/inspect commands also accept
an individual replay record saved as a regular JSON file.

## Framing and correctness

`NdjsonDecoder` is a portable immutable incremental UTF-8 framer. Feed chunks of
at most 65536 bytes; its configurable record limit is 1..4,000,000 bytes (default
4 MB), excluding LF and including an optional CR. It handles CRLF, multibyte
characters split across chunks and a final record without LF. Invalid UTF-8 is
refused, never replaced. Empty framed records are retained rather than skipped.
`finish()` returns the final unterminated string without mutating the decoder.

`ReplaySession` owns committed `State` and an exact Int64 record ordinal.
`apply_line` accepts one physical JSON record, refuses blanks/malformed data,
enforces the usual strict interval/kind/profile checks, and returns `ReplayRecord`
only on complete success. Errors identify `/records/N`. Checkpoints/receipts
are bounded to 4M JSON code units; session restore accepts core versions 1..4.
`decode_replay_record` checks the supported Cumulative output and requires the
receipt ordinal to equal session progress. Original sessions remain reusable.

Memory scales with bounded chunks/records and active state, not recording size.
Every receipt includes a checkpoint, so disk output may be larger than input.
There is no automatic state eviction or claim of a throughput advantage.

## Continuations and publication

```sh
moon run --target wasm cli -- stream-to remaining.ndjson next.ndjson last-record.json
```

Save the last accepted receipt as `last-record.json`; the input above must contain
**only the remaining records**. No prefix is skipped automatically. The checkpoint
does not authenticate an input file or verify that its earlier bytes are unchanged.
Callers own input provenance and downstream delivery acknowledgement.

Each input/output record is limited to 4 MB UTF-8 by the CLI. A sibling temporary
file is written incrementally, synced, closed and published with replacement
disabled only after all records succeed. An error, blank line, bad UTF-8 or
cancelled write publishes no partial file. Existing input/output remains intact;
the owned temporary file is cleaned up on failure. Long writes are cancellable;
only temporary-file allocation and final publication are protected. Directory
crash durability and hostile concurrent filesystem mutations remain outside the
publication contract. Empty input produces an empty output stream. No source
line is silently skipped; callers correct a bad recording and retry explicitly.

Run `moon run checks/stream.mbtx -- moon wasm` for the documented offline workflow.
It adapts the pinned official session, verifies protocol JSON/Protobuf round trips,
compares continuation with full replay, checks failures/no overwrite, and exercises
both input and output larger than 4 MB. The stress case adds synthetic metadata
and whitespace; it is not production telemetry. CI runs it on Wasm and native
Linux/macOS/Windows, while pure decoder/session tests also run on Wasm-GC and JS.

Format reference (Apache-2.0, no upstream processing code copied):
https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.166.0/exporter/fileexporter#file-format
