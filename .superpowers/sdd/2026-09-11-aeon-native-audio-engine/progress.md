docs/superpowers/plans/2026-09-11-aeon-native-audio-engine.md

Base: 51ee253c7fd134903a8982216d6a82776fb16b21; required 849a1db is an ancestor.
Task 1: in progress.

## Preflight interface map

| Tasks | Shared contract | Finding |
|---|---|---|
| 3, 5 | test/fixtures/audio/generate-fixtures.py | Sequential extension; preserve prior tests and interfaces. |
| 1, 7 | app/index.html, package.json | Sequential extension; preserve prior tests and interfaces. |
| 1, 8 | app/index.html, app/interface.css | Sequential extension; preserve prior tests and interfaces. |
| 7, 8 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 1, 9 | ios/App/App/Info.plist | Sequential extension; preserve prior tests and interfaces. |
| 6, 9 | ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 1, 10 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 4, 10 | ios/App/App/Audio/AudioEngineGraph.swift | Sequential extension; preserve prior tests and interfaces. |
| 6, 10 | ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 7, 10 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 8, 10 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 9, 10 | ios/App/App/Audio/AudioSessionController.swift, ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 1, 11 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 3, 11 | ios/App/App/Audio/MetadataProbe.swift | Sequential extension; preserve prior tests and interfaces. |
| 4, 11 | ios/App/App/Audio/AudioEngineGraph.swift, ios/App/App/Audio/ReplayGain.swift, ios/App/AppTests/ReplayGainAndEQTests.swift | Sequential extension; preserve prior tests and interfaces. |
| 6, 11 | ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 7, 11 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 8, 11 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 9, 11 | ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 10, 11 | app/index.html, ios/App/App/Audio/AudioEngineGraph.swift, ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 1, 12 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 3, 12 | ios/App/App/Audio/MediaStore.swift | Sequential extension; preserve prior tests and interfaces. |
| 7, 12 | app/index.html, app/native-audio.js, ios/App/App/Audio/NativeAudioPlugin.swift, test/native-audio-contract.mjs | Sequential extension; preserve prior tests and interfaces. |
| 8, 12 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 10, 12 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 11, 12 | app/index.html | Sequential extension; preserve prior tests and interfaces. |
| 1, 13 | app/index.html, app/interface.css | Sequential extension; preserve prior tests and interfaces. |
| 2, 13 | ios/App/App/Audio/DiagnosticsLog.swift | Sequential extension; preserve prior tests and interfaces. |
| 3, 13 | ios/App/App/Audio/MetadataProbe.swift, ios/App/AppTests/MetadataProbeTests.swift | Sequential extension; preserve prior tests and interfaces. |
| 6, 13 | ios/App/App/Audio/PlaybackCoordinator.swift, ios/App/AppTests/PlaybackCoordinatorTests.swift | Sequential extension; preserve prior tests and interfaces. |
| 7, 13 | app/index.html, ios/App/App/Audio/NativeAudioPlugin.swift | Sequential extension; preserve prior tests and interfaces. |
| 8, 13 | app/index.html, app/interface.css | Sequential extension; preserve prior tests and interfaces. |
| 9, 13 | ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 10, 13 | app/index.html, ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 11, 13 | app/index.html, ios/App/App/Audio/MetadataProbe.swift, ios/App/App/Audio/PlaybackCoordinator.swift | Sequential extension; preserve prior tests and interfaces. |
| 12, 13 | app/index.html, ios/App/App/Audio/NativeAudioPlugin.swift | Sequential extension; preserve prior tests and interfaces. |
| 1, 14 | app/sw.js | Sequential extension; preserve prior tests and interfaces. |
| 3, 14 | test/fixtures/audio/generate-fixtures.py | Sequential extension; preserve prior tests and interfaces. |
| 5, 14 | test/fixtures/audio/generate-fixtures.py | Sequential extension; preserve prior tests and interfaces. |

## Task-local review

| Task | Finding |
|---|---|
| 1 | CocoaPods requires workspace build; simulator availability must be discovered in CI. Arithmetic smoke checks linking only. |
| 2 | EQBand is consumed here but introduced in Task 4; define value type with models. |
| 3 | Stable-ID destination needs explicit extension handling and safe path validation. |
| 4 | Two players cannot both feed one EQ input directly; a neutral summing mixer is needed. |
| 5 | Output sample timeline and pause/resume must preserve exact handoff scheduling. Pure fixture math alone is not rendered evidence. |
| 6 | Snapshot needs actual transport state separate from intent, structured failure, and test injection protocols. |
| 7 | iOS missing plugin must fail explicitly, never silently choose browser. Register plugin in bridge controller. |
| 8 | Existing browser-only tests must stay active; native mode needs new mocked UI cases. |
| 9 | Remote metadata requires title/artist/album/artwork beyond listed QueueItem fields. |
| 10 | Recovery needs graph/session test seams established earlier. |
| 11 | Missing selected gain must yield unity even with nonzero preamp, per stated selection rule. |
| 12 | New imports require direct native file access, legacy bounded chunks only. |
| 13 | Decoder-open failure classification cannot assume every malformed file is unsupported. |
| 14 | Sync/pods must precede native tests. Physical evidence unavailable here and must remain pending. |

Ruling: Use CocoaPods workspace for native commands and sync/install dependencies before tests — the existing App links Pods — project-only invocation risks a false build failure.
Ruling: Wire the macOS XCTest CI gate during Task 1 — Linux cannot execute XCTest — this moves CI preparation earlier but does not waive native verification.

Native gate blocker: host is Linux, xcodebuild exits 127. GitHub git push dry-run cannot authenticate; connector create_blob returned 403 Resource not accessible by integration. Do not retry equivalent writes through alternative APIs. Finish and review Task1 source checkpoint, leave native validation open and Tasks2-14 pending.

Task 1: first checkpoint e380dd1. Review: partial spec compliance because XCTest/browser gates unobserved; source review found no defect. Controller found sibling AppTests Podfile inheritance does not inherit App pods; implementer correcting to nested target based on CocoaPods reference. Browser executable recovered from local packaged Brotli payload; suites running.

Task 2: fix round 1/5 (4 addressed, 0 open; commits 6d9d3f0..12c10b8)
Task 2: source complete (commits e0d4ee5..12c10b8, review clean; native XCTest pending external gate)

Task 3: source and deterministic fixtures prepared; focused native XCTest remains uncompiled because Linux has no xcodebuild (exit 127 before and after implementation).
