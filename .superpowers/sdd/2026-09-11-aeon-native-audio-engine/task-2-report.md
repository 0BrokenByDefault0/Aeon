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
