# Task 2 report: authoritative playback state

## Status

Prepared and committed for macOS/Xcode validation. Native compilation and XCTest execution remain blocked in the current Linux environment.

## Implemented contract

- Added explicit bridge-facing enums and value types for playback intent, ReplayGain mode, routes, media references, queue items, source/output formats, EQ bands, snapshots, and structured playback failures.
- Defined `EQBand` in `PlaybackModels.swift` because `PlaybackSnapshot` consumes it. Task 4 must reuse this definition rather than redeclare it.
- Gave `MediaReference` a stable discriminated JSON representation:
  - native: `{"type":"native","relativePath":"..."}`
  - external bookmark: `{"type":"externalBookmark","bookmark":"<base64>"}`
  - legacy blob: `{"type":"legacyBlob","trackID":"..."}`
- Added an explicit snapshot encoder so optional bridge fields remain present as JSON `null`, and defaulted new snapshots to schema version 1.
- Made `StateVersionClock` monotonic under plausible concurrent callers by protecting its counter with `NSLock`.

## Persistence and failure safety

- `PlaybackStateStore` creates its parent directory and writes `transport-v1.json` with Foundation's atomic write option.
- Loading accepts only schema version 1. Missing, corrupt, or incompatible data returns `nil`; loading never rewrites or deletes the stored bytes or mutates library data.
- Focused tests cover round trips, replacement of an existing snapshot, parent creation, schema rejection, and preservation of corrupt bytes.

## Diagnostics

- Added a lock-protected in-memory ring and atomically persisted JSON-lines file.
- Both entry count and serialized UTF-8 byte size are hard bounds. Oversized oldest entries are removed before the atomic write, leaving a valid JSON-lines file (possibly empty if one entry alone exceeds the byte limit).
- Diagnostic writes are synchronous by design. Later render-path callers must dispatch off the render thread; this task does not invent asynchronous ownership.
- The only file-derived value retained is a validated lowercase extension. Absolute paths and `file://` values are centrally redacted from every caller-provided string field, including values loaded from an existing log.

## Tests and evidence

The required focused command was invoked before test/production implementation and again after implementation:

```text
npm run test:ios -- -only-testing:AppTests/PlaybackModelsTests -only-testing:AppTests/PlaybackStateStoreTests
```

Both invocations exited 127 with:

```text
sh: 1: xcodebuild: not found
```

This is environmental evidence only. It does not show the intended red compile failure and does not establish a green native test result. A separate `swiftc -typecheck` attempt was also unavailable because this image has no Swift compiler. `git diff --check` passed, and Xcode project references/source memberships were inspected directly.

## Self-review

- Confirmed all three production sources are members of the App Sources phase and both new XCTest files are members of AppTests Sources.
- Confirmed no iOS-only API is used; the implementation is Foundation-only and compatible with the iOS 13 deployment floor.
- Confirmed no UI files changed and the Task 1 evidence remains intact.
- Re-read the Task 2 brief and relevant design state, diagnostics, and corruption sections against the final diff.

## Remaining gate

Run the focused XCTest command on macOS with Xcode, then investigate any compiler or runtime failures before treating Task 2 as verified.

## Review changes

The requested review fixes were applied in a follow-up commit:

- Startup now sanitizes and applies both bounds to decoded JSON-lines, then best-effort atomically rewrites an existing log. Failure to rewrite during non-throwing initialization does not crash; the in-memory view remains sanitized and bounded.
- Route names are canonicalized to `AudioRouteKind.rawValue`. Codec/container values are lowercased only when present in explicit stable allowlists; arbitrary device labels and hostile free text are omitted.
- `record` now stages and bounds a candidate ring, persists it atomically, and replaces the in-memory ring only after persistence succeeds. A deterministic invalid-parent test confirms write failure leaves entries unchanged.
- `StateVersionClock.next()` now returns `UInt64?`: it returns the next strictly increasing value or `nil` at exhaustion. This is a deliberate small compatibility change because neither crashing nor returning `UInt64.max` repeatedly satisfies the monotonic-increase contract.
- Snapshot timestamps have an explicit seconds-since-Unix-epoch JSON convention. Tests lock the timestamp value, optional `null` fields and their decoding, missing-schema rejection, existing-log sanitization/count/byte rewrites, and zero count/byte behavior.

Review-cycle focused test command:

```text
npm run test:ios -- -only-testing:AppTests/PlaybackModelsTests -only-testing:AppTests/PlaybackStateStoreTests
```

Pre-fix/red invocation output and exit status:

```text
sh: 1: xcodebuild: not found
exit 127
```

Post-fix invocation output and exit status:

```text
sh: 1: xcodebuild: not found
exit 127
```

This Linux environment still cannot provide native compilation or XCTest pass evidence.
