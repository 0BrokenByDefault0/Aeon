# Aeon Native Audio Engine 5.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Aeon's browser-owned iOS playback path with a fidelity-first native `AVAudioEngine` transport while preserving the Aeon 4.6.1 interface, library semantics, queue behavior, and constellation experience.

**Architecture:** Keep HTML/CSS/JavaScript as the product/UI layer and make a Capacitor `NativeAudio` plugin the only iOS playback entry point. A serially-confined `PlaybackCoordinator` owns authoritative transport state and delegates file access, AVAudioEngine graph/scheduling, session lifecycle, remote commands, persistence, telemetry, and diagnostics to focused Swift components. Browser audio remains only as an explicit non-iOS fallback/test engine.

**Tech Stack:** Capacitor 6, Swift, AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioFile`, `AVAudioUnitEQ`, `AVAudioSession`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), Foundation file APIs, XCTest, existing Node/Playwright browser regressions.

**Spec:** `docs/superpowers/specs/2026-09-11-aeon-native-audio-engine-design.md`

## Global Constraints

- Release target is **Aeon 5.0**, not a 4.6.x web-only patch.
- Preserve bundle identifier `app.isolation.sky`.
- Start from the approved Aeon 4.6.1 / build 49 UI and behavior baseline.
- iOS deployment floor remains **13.0** unless an implementation dependency proves impossible on iOS 13; any increase requires an explicit product decision before merge.
- iOS native mode must not depend on HTML `<audio>` timing once native transport is enabled.
- Optional processing defaults: ReplayGain `off`, EQ bypassed, preamp `0.0 dB`, master volume unity.
- No hidden limiter, compressor, exciter, spatializer, loudness enhancer, stereo widener, or automatic source modification.
- Source files are never destructively rewritten.
- Native is authoritative for loaded track, queue index, playback intent/state, position, gapless scheduling, output route/format, and recovery state.
- JS owns library presentation, playlists, navigation, constellation rendering, user controls, and display of native telemetry.
- Native/JS events carry a monotonically increasing version. JS ignores stale versions.
- Route loss safety: wired/Bluetooth/USB output removal pauses playback; do not fall through unexpectedly to the phone speaker.
- Corrupt, missing, or unsupported files remain in the library and surface an explicit error; 5.0 defaults to stop-and-explain rather than silently skipping.
- Existing UI language remains sparse and on-theme: no generic technical dashboard, pill-heavy controls, or visual redesign during this engine migration.
- Crossfade, limiter, loudness analysis, headphone correction, convolution, spatialization, AUv3 hosting, streaming services, and SwiftUI rewrite are deferred.
- Physical-device evidence is required before calling the engine audio-complete; simulator/unit/browser evidence must be reported separately.
- Canonical source precondition: execution requires a writable checkout containing Aeon's source history at base commit `849a1dbbdf66b37491964b54470241920fc6d9e3` (or a descendant containing the cumulative 4.x changes). The approved 4.6.1 web assets must be restored into that checkout before native work starts.

---

## File Structure

Create these focused native units under `ios/App/App/Audio/`:

- `PlaybackModels.swift` — Codable/bridge-safe value types, state versioning, queue/media/format/error descriptors.
- `DiagnosticsLog.swift` — bounded local diagnostic ring buffer.
- `PlaybackStateStore.swift` — versioned crash-safe transport snapshot persistence.
- `MediaStore.swift` — canonical native media paths, transactional import/migration, missing-file detection.
- `MetadataProbe.swift` — `AVAudioFile`/asset capability and source-format inspection.
- `AudioEngineGraph.swift` — `AVAudioEngine`, nodes, EQ, output/master gain, graph rebuilds.
- `QueueScheduler.swift` — A/B node scheduling, seek, cancellation generation, gapless handoff.
- `AudioSessionController.swift` — `AVAudioSession` activation, route/interruption/media-services notifications and normalized policy events.
- `RemoteCommandCoordinator.swift` — lock-screen/Control Center metadata and commands.
- `PlaybackCoordinator.swift` — single serialized authority combining all units.
- `NativeAudioPlugin.swift` — thin Capacitor bridge, command validation, event publication.

Create/modify web files:

- Create `app/native-audio.js` — transport adapter with native implementation + explicit browser fallback/mock seam.
- Modify `app/index.html` — route existing play/pause/seek/queue UI through adapter, remove iOS ownership from `<audio>`, surface minimal telemetry/errors.
- Modify `app/interface.css` only for the minimal source/output/replaygain/error labels required by 5.0.
- Modify `app/sw.js` cache version for Aeon 5.0.

Create native tests under `ios/App/AppTests/`:

- `PlaybackModelsTests.swift`
- `PlaybackStateStoreTests.swift`
- `MediaStoreTests.swift`
- `MetadataProbeTests.swift`
- `QueueSchedulerTests.swift`
- `AudioSessionPolicyTests.swift`
- `PlaybackCoordinatorTests.swift`
- `ReplayGainAndEQTests.swift`

Create browser/contract tests:

- `test/native-audio-contract.mjs`
- Update `test/run.mjs`, `test/interface.mjs`, `test/arrival.mjs` to use a deterministic mock `NativeAudio` bridge in native-mode test cases.

Create test media under `test/fixtures/audio/`:

- deterministic PCM WAV source
- split WAV pair for gapless boundary
- 44.1/48/96 kHz fixtures
- corrupt/truncated fixture
- supported compressed-format fixtures that can be legally generated in-repo by test scripts

Create release evidence:

- `docs/releases/5.0.md`
- `docs/validation/5.0-audio-device-matrix.md`

---

### Task 1: Restore the 4.6.1 source baseline and establish a native test target

**Files:**
- Modify: `ios/App/App.xcodeproj/project.pbxproj`
- Modify: `ios/App/App/Info.plist`
- Modify: `app/index.html`
- Modify: `app/interface.css`
- Modify: `app/sw.js`
- Create: `ios/App/AppTests/SmokeTests.swift`
- Modify: `package.json`

**Interfaces:**
- Consumes: canonical repository containing commit `849a1dbbdf66b37491964b54470241920fc6d9e3`; approved 4.6.1 packaged web assets.
- Produces: a clean source tree whose web UI matches 4.6.1, an Xcode test target named `AppTests`, and a fresh-build path for 5.0.

- [ ] **Step 1: Restore current web assets and write the failing native smoke test**

Restore `Payload/App.app/public/*` from the approved 4.6.1 IPA over the source `app/` assets that correspond to packaged files. Do not copy native binary/framework contents back into source.

Create `ios/App/AppTests/SmokeTests.swift`:

```swift
import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testAeonFiveNativeTestTargetLoads() {
        XCTAssertEqual(2 + 2, 4)
    }
}
```

Set the source project marketing version/build to `5.0` / `50`, retain `UIBackgroundModes = [audio]`, and add `AppTests` to the Xcode project.

- [ ] **Step 2: Run baseline checks and verify the new native target is the only expected failure**

Run on macOS with Xcode installed:

```bash
npm ci --no-audit --no-fund
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
xcodebuild -project ios/App/App.xcodeproj \
  -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

Expected before the test-target/project wiring is finished: web suites pass; `xcodebuild test` fails because `AppTests` is not yet fully configured or linked.

- [ ] **Step 3: Finish the fresh native build/test wiring**

Ensure `AppTests` links the application target and XCTest. Add an npm convenience command:

```json
"test:ios": "xcodebuild -project ios/App/App.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test"
```

Do not reuse `scripts/package-unsigned.py` as the Aeon 5.0 build mechanism; it may remain for historical 4.x packaging only.

- [ ] **Step 4: Re-run baseline + native smoke test**

Run:

```bash
npm test && npm run check && npm run test:browser && npm run test:interface && npm run test:arrival
npm run test:ios
```

Expected: all current browser/library/interface regressions pass and `SmokeTests` passes in the iOS simulator.

- [ ] **Step 5: Commit**

```bash
git add app ios/App package.json package-lock.json
git commit -m "build: establish Aeon 5 native source baseline"
```

---

### Task 2: Define bridge-safe playback models, versioned state, diagnostics, and persistence

**Files:**
- Create: `ios/App/App/Audio/PlaybackModels.swift`
- Create: `ios/App/App/Audio/DiagnosticsLog.swift`
- Create: `ios/App/App/Audio/PlaybackStateStore.swift`
- Create: `ios/App/AppTests/PlaybackModelsTests.swift`
- Create: `ios/App/AppTests/PlaybackStateStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum PlaybackIntent: String, Codable { case playing, paused }`
  - `enum ReplayGainMode: String, Codable { case off, album, track }`
  - `enum AudioRouteKind: String, Codable { case speaker, wired, bluetooth, airPlay, usb, unknown }`
  - `enum MediaReference: Codable, Equatable { case native(relativePath: String); case externalBookmark(Data); case legacyBlob(trackID: String) }`
  - `struct QueueItem: Codable, Equatable { let trackID: String; let albumID: String; let mediaRef: MediaReference }`
  - `struct SourceFormatDescriptor: Codable, Equatable { let codec: String?; let container: String?; let sampleRate: Double?; let channelCount: Int?; let bitDepth: Int?; let duration: Double? }`
  - `struct OutputFormatDescriptor: Codable, Equatable { let sampleRate: Double; let channelCount: Int; let route: RouteDescriptor }`
  - `struct RouteDescriptor: Codable, Equatable { let kind: AudioRouteKind; let name: String; let sampleRate: Double?; let channelCount: Int? }`
  - `struct PlaybackSnapshot: Codable, Equatable` with `schemaVersion` defaulting to `1`
  - `struct PlaybackFailure: Error, Codable, Equatable { let code: String; let message: String; let recoverable: Bool; let trackID: String? }`
  - `final class StateVersionClock`
  - `final class PlaybackStateStore`
  - `final class DiagnosticsLog`

- [ ] **Step 1: Write failing model/persistence tests**

Create tests that lock the serialized contract:

```swift
func testPlaybackSnapshotRoundTripsWithoutLosingVersion() throws {
    let snapshot = PlaybackSnapshot(
        version: 12,
        trackID: "t1",
        queueRevision: 4,
        queue: [QueueItem(trackID: "t1", albumID: "a1", mediaRef: .native(relativePath: "Music/a1/t1.flac"))],
        queueIndex: 0,
        position: 42.25,
        intent: .paused,
        replayGainMode: .off,
        replayGainPreampDB: 0,
        masterVolume: 1,
        eqEnabled: false,
        eqBands: [],
        route: nil,
        sourceFormat: nil,
        outputFormat: nil,
        timestamp: Date(timeIntervalSince1970: 100)
    )
    let data = try JSONEncoder().encode(snapshot)
    XCTAssertEqual(try JSONDecoder().decode(PlaybackSnapshot.self, from: data), snapshot)
}

func testStateVersionClockOnlyMovesForward() {
    let clock = StateVersionClock(seed: 8)
    XCTAssertEqual(clock.next(), 9)
    XCTAssertEqual(clock.next(), 10)
}
```

Persistence test must also verify incompatible/corrupt JSON returns a safe nil/stopped result rather than mutating library data.

- [ ] **Step 2: Run tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/PlaybackModelsTests \
  -only-testing:AppTests/PlaybackStateStoreTests
```

Expected: compile failures because the model/store types do not exist.

- [ ] **Step 3: Implement the model contract and bounded local stores**

Use explicit Codable structs. `PlaybackStateStore` writes atomically into Application Support:

```swift
final class PlaybackStateStore {
    private let url: URL
    init(baseURL: URL) { self.url = baseURL.appendingPathComponent("transport-v1.json") }

    func save(_ snapshot: PlaybackSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func load() -> PlaybackSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
              value.schemaVersion == 1 else { return nil }
        return value
    }
}
```

`DiagnosticsLog` is an in-memory ring plus atomic JSON-lines file capped by entry count/size. Log stable IDs and normalized route/format values; never require absolute user file paths.

- [ ] **Step 4: Run model/store tests**

```bash
npm run test:ios -- -only-testing:AppTests/PlaybackModelsTests \
  -only-testing:AppTests/PlaybackStateStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests
git commit -m "feat(audio): define authoritative playback state"
```

---

### Task 3: Add MediaStore and MetadataProbe with explicit format capability

**Files:**
- Create: `ios/App/App/Audio/MediaStore.swift`
- Create: `ios/App/App/Audio/MetadataProbe.swift`
- Create: `ios/App/AppTests/MediaStoreTests.swift`
- Create: `ios/App/AppTests/MetadataProbeTests.swift`
- Create: `test/fixtures/audio/generate-fixtures.py`
- Create generated fixtures under: `test/fixtures/audio/`

**Interfaces:**
- Consumes: `MediaReference`, `SourceFormatDescriptor`.
- Produces:
  - `struct ProbedMedia: Equatable`
  - `enum MediaCapability { case playable(ProbedMedia), unsupported(reason: String), unavailable }`
  - `protocol MediaResolving { func resolve(_ reference: MediaReference) throws -> URL }`
  - `final class MediaStore: MediaResolving`
  - `final class MetadataProbe { func probe(url: URL) -> MediaCapability }`

- [ ] **Step 1: Write failing transactional-copy and probe tests**

Key MediaStore test:

```swift
func testImportDoesNotReplaceExistingMediaUntilVerified() throws {
    let store = try MediaStore(baseURL: tempURL)
    let source = tempURL.appendingPathComponent("incoming.wav")
    try Data([0,1,2,3]).write(to: source)
    XCTAssertThrowsError(try store.importFile(sourceURL: source, stableID: "track-1", verifier: { _ in false }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(stableID: "track-1").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
}
```

Metadata tests generate valid WAV fixtures at 44.1/48/96 kHz and assert normalized sample rate/channel/duration fields. Add corrupt and missing-file cases.

- [ ] **Step 2: Run tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/MediaStoreTests \
  -only-testing:AppTests/MetadataProbeTests
```

Expected: missing types/functions.

- [ ] **Step 3: Implement MediaStore and MetadataProbe**

MediaStore root:

```swift
Application Support/Aeon/Media/
```

Import algorithm:

```text
source → .incoming/<stableID>.partial → fsync/close → verifier opens/probes → atomic move to Media/<stableID>.<ext>
```

`MetadataProbe.probe` first attempts `AVAudioFile(forReading:)`; normalize `processingFormat.sampleRate`, `channelCount`, `length`, duration, and format identifiers that AVFoundation exposes. If the system decoder cannot open OGG/OPUS, return `.unsupported(reason:)`; do not transcode or delete.

- [ ] **Step 4: Run MediaStore/probe tests and fixture capability matrix**

```bash
python3 test/fixtures/audio/generate-fixtures.py
npm run test:ios -- -only-testing:AppTests/MediaStoreTests \
  -only-testing:AppTests/MetadataProbeTests
```

Expected: common required fixtures probe successfully; corrupt/missing fixtures return explicit non-playable states; OGG/OPUS result is recorded rather than guessed.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests test/fixtures/audio
git commit -m "feat(audio): add native media store and metadata probe"
```

---

### Task 4: Build the transparent single-track AVAudioEngine graph

**Files:**
- Create: `ios/App/App/Audio/AudioEngineGraph.swift`
- Create: `ios/App/App/Audio/ReplayGain.swift`
- Create: `ios/App/AppTests/ReplayGainAndEQTests.swift`
- Create: `ios/App/AppTests/AudioEngineGraphTests.swift`

**Interfaces:**
- Consumes: playable native URL, source descriptor.
- Produces:
  - `struct EQBand: Codable, Equatable { frequency: Double, q: Double, gainDB: Double }`
  - `struct ReplayGainValues: Codable, Equatable { trackGainDB: Double?, albumGainDB: Double?, trackPeak: Double?, albumPeak: Double? }` with `static let empty` containing four nil values
  - `enum AudioSlot { case a, b }`
  - `final class AudioEngineGraph`
  - `func replayGainDB(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Double`
  - `func replayGainScalar(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Float`

`AudioEngineGraph` required methods:

```swift
func configure() throws
func open(url: URL, in slot: AudioSlot) throws -> AVAudioFile
func play(slot: AudioSlot, fromFrame: AVAudioFramePosition?) throws
func pause()
func stop()
func seek(slot: AudioSlot, to seconds: Double) throws
func setMasterVolume(_ linear: Float)
func setReplayGain(_ scalar: Float, slot: AudioSlot)
func setEQ(enabled: Bool, bands: [EQBand]) throws
func outputDescriptor() -> OutputFormatDescriptor
func rebuild() throws
```

- [ ] **Step 1: Write failing transparency/ReplayGain/EQ tests**

ReplayGain math test:

```swift
func testReplayGainOffIsUnity() {
    XCTAssertEqual(replayGainScalar(mode: .off, values: .init(trackGainDB: -7, albumGainDB: -5, trackPeak: 1, albumPeak: 1), preampDB: 6), 1, accuracy: 0.000001)
}

func testTrackReplayGainUsesDBToLinearConversion() {
    let scalar = replayGainScalar(mode: .track, values: .init(trackGainDB: -6, albumGainDB: nil, trackPeak: nil, albumPeak: nil), preampDB: 0)
    XCTAssertEqual(scalar, Float(pow(10.0, -6.0/20.0)), accuracy: 0.00001)
}
```

Graph test must assert EQ starts bypassed and master/replay gains default to unity.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/ReplayGainAndEQTests \
  -only-testing:AppTests/AudioEngineGraphTests
```

- [ ] **Step 3: Implement graph with no hidden processors**

Graph topology:

```text
playerA ─┐
         ├──> AVAudioUnitEQ (bypass=true) ──> mainMixer ──> output
playerB ─┘
```

Use each player node's `volume` for per-slot ReplayGain scalar and `mainMixerNode.outputVolume` for user master volume. Connect with formats that permit AVAudioEngine to negotiate conversion. No limiter or compressor node exists.

EQ uses the legacy 10-band frequencies only as the initial band model when legacy values are migrated; it remains bypassed until enabled.

- [ ] **Step 4: Run graph/math tests**

```bash
npm run test:ios -- -only-testing:AppTests/ReplayGainAndEQTests \
  -only-testing:AppTests/AudioEngineGraphTests
```

Expected: PASS; a graph can start/stop against simulator audio, EQ remains bypassed by default, ReplayGain off is exact unity scalar.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests
git commit -m "feat(audio): add transparent native audio graph"
```

---

### Task 5: Implement QueueScheduler with deterministic A/B scheduling, seeking, and gapless fixtures

**Files:**
- Create: `ios/App/App/Audio/QueueScheduler.swift`
- Create: `ios/App/AppTests/QueueSchedulerTests.swift`
- Extend: `test/fixtures/audio/generate-fixtures.py`
- Create: `test/fixtures/audio/gapless-a.wav`
- Create: `test/fixtures/audio/gapless-b.wav`

**Interfaces:**
- Consumes: `AudioEngineGraph`, `MediaResolving`, `QueueItem`, `MetadataProbe`.
- Produces:
  - `struct ScheduleToken: Equatable { let generation: UInt64 }`
  - `enum SchedulerEvent { case started(...), handoff(...), completed(...), failed(...) }`
  - `final class QueueScheduler`

Required methods:

```swift
func setQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws
func prepareCurrent(position: Double) throws
func play() throws
func pause()
func seek(seconds: Double) throws
func next() throws
func previous() throws
func replaceQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws
func invalidatePendingSchedule()
```

- [ ] **Step 1: Write failing scheduling and stale-generation tests**

```swift
func testQueueReplacementInvalidatesPreviouslyPreparedNextTrack() throws {
    let scheduler = makeScheduler(queue: [a,b])
    try scheduler.prepareCurrent(position: 0)
    let old = scheduler.currentGeneration
    try scheduler.replaceQueue([a,c], index: 0, revision: 2)
    XCTAssertGreaterThan(scheduler.currentGeneration, old)
    XCTAssertEqual(scheduler.preparedNextTrackID, "c")
}
```

Add a deterministic continuous sine fixture split at an exact PCM frame. The test harness should capture/render the graph offline where the platform permits; otherwise isolate boundary math into a pure scheduling calculation that can be compared sample-for-sample and keep a device integration test for final audio capture.

Define WAV gapless tolerance for automated PCM fixture: **0 inserted frames, 0 duplicated frames at the expected decoded boundary**. Compressed-codec tolerances are added only after codec fixtures establish decoder padding behavior.

- [ ] **Step 2: Run scheduler tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/QueueSchedulerTests
```

- [ ] **Step 3: Implement A/B scheduling**

Rules:

```text
current slot = A, next slot = B
open current
open/prepare next before current completion
compute boundary on engine/output timeline
schedule next at that boundary
completion from an obsolete generation is ignored
handoff flips current/next slots and immediately prepares the following item
```

Do not use JavaScript timers or a bridge call for end-of-track handoff.

- [ ] **Step 4: Run queue/gapless tests**

```bash
python3 test/fixtures/audio/generate-fixtures.py
npm run test:ios -- -only-testing:AppTests/QueueSchedulerTests
```

Expected: queue replacement, rapid skip, seek, and same-rate WAV boundary tests pass with no stale completion changing current state.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests test/fixtures/audio
git commit -m "feat(audio): schedule native gapless queues"
```

---

### Task 6: Implement PlaybackCoordinator as the single serialized transport authority

**Files:**
- Create: `ios/App/App/Audio/PlaybackCoordinator.swift`
- Create: `ios/App/AppTests/PlaybackCoordinatorTests.swift`

**Interfaces:**
- Consumes: scheduler, state store, diagnostics, metadata/media services.
- Produces:
  - `protocol PlaybackCoordinatorDelegate: AnyObject`
  - `final class PlaybackCoordinator`
  - all bridge and remote commands converge on this class.

Use a dedicated serial queue for iOS 13 compatibility:

```swift
private let transportQueue = DispatchQueue(label: "app.aeon.audio.transport", qos: .userInitiated)
```

Required command methods:

```swift
func initialize(completion: @escaping (Result<PlaybackSnapshot, PlaybackFailure>) -> Void)
func load(trackID: String, mediaRef: MediaReference, queue: [QueueItem]?, index: Int?, completion: ...)
func play(completion: ...)
func pause(completion: ...)
func seek(seconds: Double, completion: ...)
func next(completion: ...)
func previous(completion: ...)
func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: ...)
func setVolume(_ value: Float, completion: ...)
func setReplayGainMode(_ mode: ReplayGainMode, completion: ...)
func setReplayGainPreamp(_ db: Double, completion: ...)
func setEQ(enabled: Bool, bands: [EQBand], completion: ...)
func getState(completion: @escaping (PlaybackSnapshot) -> Void)
```

- [ ] **Step 1: Write failing state-machine tests**

Cover:
- play cannot create two simultaneous starts
- stale completion after rapid `load(A) → load(B)` cannot return state to A
- pause changes user intent to `.paused`
- temporary interruption state does not overwrite user intent
- snapshot version increments for each externally visible mutation
- queue revision mismatch invalidates old next scheduling

Example:

```swift
func testLateLoadCompletionCannotReplaceNewerTrack() {
    let h = CoordinatorHarness()
    h.coordinator.load(trackID: "A", mediaRef: h.a, queue: nil, index: nil) { _ in }
    h.coordinator.load(trackID: "B", mediaRef: h.b, queue: nil, index: nil) { _ in }
    h.completeOpen(trackID: "A")
    h.completeOpen(trackID: "B")
    XCTAssertEqual(h.snapshot.trackID, "B")
}
```

- [ ] **Step 2: Run coordinator tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/PlaybackCoordinatorTests
```

- [ ] **Step 3: Implement serialized coordinator and checkpointing**

Every public method marshals onto `transportQueue`. Async callbacks capture an operation generation and return early if stale. Every published snapshot uses `StateVersionClock.next()`, persists the transport checkpoint where appropriate, and emits diagnostics without blocking the audio render thread.

- [ ] **Step 4: Run coordinator + prior audio tests**

```bash
npm run test:ios -- -only-testing:AppTests/PlaybackCoordinatorTests \
  -only-testing:AppTests/QueueSchedulerTests \
  -only-testing:AppTests/PlaybackStateStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests
git commit -m "feat(audio): centralize native transport authority"
```

---

### Task 7: Expose the native engine through a thin Capacitor plugin and JS adapter

**Files:**
- Create: `ios/App/App/Audio/NativeAudioPlugin.swift`
- Create: `app/native-audio.js`
- Modify: `app/index.html`
- Create: `test/native-audio-contract.mjs`
- Modify: `package.json`

**Interfaces:**
- Consumes: `PlaybackCoordinator`.
- Produces native methods named exactly:
  - `initialize`, `load`, `play`, `pause`, `toggle`, `seek`, `next`, `previous`
  - `setQueue`, `updateQueue`, `setVolume`
  - `setReplayGainMode`, `setReplayGainPreamp`
  - `setEQEnabled`, `setEQBands`
  - `getState`, `getDiagnostics`
- Produces events named exactly:
  - `stateChanged`, `positionChanged`, `trackChanged`, `queueChanged`, `routeChanged`, `formatChanged`, `interruptionChanged`, `engineRecovered`, `mediaUnavailable`, `playbackError`
- Produces JS singleton `window.aeonTransport` with the same high-level command names and `subscribe(handler)`.

- [ ] **Step 1: Write failing JS contract tests with a fake native plugin**

`test/native-audio-contract.mjs` injects:

```js
window.Capacitor = {
  isNativePlatform: () => true,
  Plugins: { NativeAudio: fakeNativeAudio }
};
```

Test requirements:

```js
assert.equal(await page.evaluate(() => aeonTransport.kind), 'native');
await page.evaluate(() => aeonTransport.play());
assert.equal(fake.calls.at(-1).name, 'play');

fake.emit('stateChanged', { version: 9, trackID: 'new' });
fake.emit('stateChanged', { version: 8, trackID: 'old' });
assert.equal(await page.evaluate(() => aeonTransport.state.trackID), 'new');
```

- [ ] **Step 2: Run contract test and confirm failure**

```bash
node test/native-audio-contract.mjs
```

Expected: missing `aeonTransport`/NativeAudio plugin bridge.

- [ ] **Step 3: Implement plugin and adapter**

Swift bridge skeleton:

```swift
@objc(NativeAudioPlugin)
public final class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "initialize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "toggle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "next", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "previous", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setReplayGainMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setReplayGainPreamp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEQEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEQBands", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDiagnostics", returnType: CAPPluginReturnPromise)
    ]
}
```

Each `@objc` method parses only its own documented arguments and forwards one command to `PlaybackCoordinator`; the event delegate maps coordinator outputs to the exact event names above. The plugin validates JSON arguments, calls only `PlaybackCoordinator`, resolves/rejects structured results, and uses `notifyListeners` for versioned events. It contains no queue/audio policy.

`app/native-audio.js` selects native transport only when the app is running natively and the plugin is available. Browser tests/dev use an explicit web fallback. iOS must not instantiate competing native + web transports.

- [ ] **Step 4: Run bridge contract + simulator tests**

```bash
node test/native-audio-contract.mjs
npm run test:ios -- -only-testing:AppTests/PlaybackCoordinatorTests
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio app/native-audio.js app/index.html test/native-audio-contract.mjs package.json package-lock.json
git commit -m "feat(audio): bridge Aeon UI to native transport"
```

---

### Task 8: Replace iOS browser transport ownership without changing Aeon's interaction model

**Files:**
- Modify: `app/index.html`
- Modify: `app/interface.css`
- Modify: `test/run.mjs`
- Modify: `test/interface.mjs`
- Modify: `test/arrival.mjs`

**Interfaces:**
- Consumes: `window.aeonTransport`.
- Produces: existing Aeon buttons/queue/search/resume UI bound to native authoritative snapshots in iOS mode.

- [ ] **Step 1: Add failing regression tests for native-mode UI behavior**

Mock native state in Playwright and assert:
- play glyph follows native state, not `HTMLAudioElement.paused`
- seek calls native `seek(seconds)`
- next/previous call native commands
- queue edits send one native queue revision update
- foreground/reload calls `getState()` and redraws
- stale event versions cannot roll UI backwards
- no `audio.play()` call occurs in native mode

- [ ] **Step 2: Run browser/interface tests and confirm native-mode failures**

```bash
node test/native-audio-contract.mjs
npm run test:browser
npm run test:interface
npm run test:arrival
```

- [ ] **Step 3: Refactor existing transport functions to adapter calls**

Preserve function names used by the rest of Aeon where practical (`togglePlay`, `playCurrent`, `nextTrack`, queue mutation hooks), but make them delegate to `aeonTransport` in native mode. Keep the existing `<audio>`/WebAudio graph only inside the explicit browser fallback path.

On `visibilitychange`, `pageshow`, or native app foreground, request a full native snapshot rather than attempting to “revive” an AudioContext.

Add minimal telemetry slots in the existing player details hierarchy:

```html
<span id="sourceFormat" hidden></span>
<span id="outputFormat" hidden></span>
```

No new dashboard/pill group.

- [ ] **Step 4: Run all browser regressions**

```bash
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
node test/native-audio-contract.mjs
```

Expected: existing Aeon UI/library/queue/search behavior passes with either fallback transport or mocked native transport.

- [ ] **Step 5: Commit**

```bash
git add app test
git commit -m "refactor(audio): make iOS UI consume native playback state"
```

---

### Task 9: Add AVAudioSession policy, background behavior, Control Center, and interruption handling

**Files:**
- Create: `ios/App/App/Audio/AudioSessionController.swift`
- Create: `ios/App/App/Audio/RemoteCommandCoordinator.swift`
- Create: `ios/App/AppTests/AudioSessionPolicyTests.swift`
- Modify: `ios/App/App/Audio/PlaybackCoordinator.swift`
- Verify/Modify: `ios/App/App/Info.plist`

**Interfaces:**
- Produces:
  - `enum SessionEvent { case interruptionBegan, interruptionEnded(shouldResume: Bool), routeChanged(RouteChange), mediaServicesReset, mediaServicesLost }`
  - pure policy helper `func routeLossAction(old: RouteDescriptor?, new: RouteDescriptor?, reason: AVAudioSession.RouteChangeReason) -> RouteLossAction`
  - `AudioSessionController.delegate`
  - `RemoteCommandCoordinator` callbacks into `PlaybackCoordinator` only.

- [ ] **Step 1: Write failing policy tests**

Examples:

```swift
func testHeadphonesRemovedPausesInsteadOfFallingBackToSpeaker() {
    let old = RouteDescriptor(kind: .usb, name: "USB DAC", sampleRate: 96_000, channelCount: 2)
    let new = RouteDescriptor(kind: .speaker, name: "iPhone", sampleRate: 48_000, channelCount: 2)
    XCTAssertEqual(routeLossAction(old: old, new: new, reason: .oldDeviceUnavailable), .pauseAndRebuild)
}

func testInterruptionEndDoesNotResumeWhenUserIntentWasPaused() {
    let decision = interruptionResumeDecision(systemSaysResume: true, userIntent: .paused)
    XCTAssertFalse(decision)
}
```

- [ ] **Step 2: Run tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/AudioSessionPolicyTests
```

- [ ] **Step 3: Implement session + remote command coordinators**

Configure:

```swift
try session.setCategory(.playback, mode: .default, options: [])
try session.setActive(true)
```

Observe interruption, route-change, media-services-lost/reset. Convert notifications into normalized events; do not mutate transport directly inside notification callbacks.

Remote command handlers call `PlaybackCoordinator.play/pause/next/previous/seek`. `MPNowPlayingInfoCenter` receives title, artist, album, artwork, duration, elapsed time, and rate from authoritative snapshots.

- [ ] **Step 4: Run policy/coordinator tests and simulator background smoke test**

```bash
npm run test:ios -- -only-testing:AppTests/AudioSessionPolicyTests \
  -only-testing:AppTests/PlaybackCoordinatorTests
```

Then manually in simulator: start playback, background app, confirm engine remains active and lock-screen metadata updates where simulator support permits. Record simulator limitations; do not treat this as physical-route proof.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests ios/App/App/Info.plist
git commit -m "feat(audio): integrate iOS session and remote controls"
```

---

### Task 10: Implement bounded engine/session recovery and truthful output telemetry

**Files:**
- Modify: `ios/App/App/Audio/AudioEngineGraph.swift`
- Modify: `ios/App/App/Audio/AudioSessionController.swift`
- Modify: `ios/App/App/Audio/PlaybackCoordinator.swift`
- Create: `ios/App/AppTests/RecoveryTests.swift`
- Modify: `app/index.html`

**Interfaces:**
- Produces recovery result:

```swift
enum RecoveryLevel: Int, Codable { case node = 1, engine = 2, session = 3 }
struct RecoveryResult: Codable, Equatable { let level: RecoveryLevel; let resumed: Bool }
```

- [ ] **Step 1: Write failing bounded-recovery tests**

Use injectable graph/session fakes to assert:
- node recovery attempted first
- engine rebuild occurs after node recovery fails
- session reactivation occurs after engine recovery fails
- retries stop after level 3
- failed recovery produces a stopped snapshot + structured error
- successful recovery restores queue index/position and resumes only when user intent is `.playing`

- [ ] **Step 2: Run recovery tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/RecoveryTests
```

- [ ] **Step 3: Implement recovery hierarchy and format observation**

Recovery flow:

```text
checkpoint → level 1 reschedule node →
if failed: rebuild engine graph/reopen/seek/reschedule →
if failed: reactivate session + rebuild graph →
if failed: stop safely + emit playbackError
```

After session/graph activation, construct `OutputFormatDescriptor` from actual native state (`AVAudioSession.sampleRate`, current route outputs, engine/output channel information). Do not infer Bluetooth/AirPlay codec fields not reliably exposed by the platform.

- [ ] **Step 4: Run recovery suite and bridge telemetry test**

```bash
npm run test:ios -- -only-testing:AppTests/RecoveryTests \
  -only-testing:AppTests/PlaybackCoordinatorTests
node test/native-audio-contract.mjs
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests app/index.html
git commit -m "feat(audio): recover native playback and report actual output"
```

---

### Task 11: Finish ReplayGain metadata application and native EQ migration

**Files:**
- Modify: `ios/App/App/Audio/MetadataProbe.swift`
- Modify: `ios/App/App/Audio/ReplayGain.swift`
- Modify: `ios/App/App/Audio/AudioEngineGraph.swift`
- Modify: `ios/App/App/Audio/PlaybackCoordinator.swift`
- Modify: `ios/App/AppTests/ReplayGainAndEQTests.swift`
- Modify: `app/index.html`

**Interfaces:**
- Consumes metadata fields `trackGainDB`, `albumGainDB`, `trackPeak`, `albumPeak` when present.
- Produces deterministic Off/Album/Track gain application and persisted native 10-band initial EQ model.

- [ ] **Step 1: Add failing ReplayGain selection/headroom and EQ persistence tests**

```swift
func testAlbumModeUsesAlbumGainNotTrackGain() {
    let values = ReplayGainValues(trackGainDB: -3, albumGainDB: -8, trackPeak: 1.0, albumPeak: 0.9)
    XCTAssertEqual(replayGainDB(mode: .album, values: values, preampDB: 0), -8)
}

func testMissingReplayGainMetadataFallsBackToUnity() {
    XCTAssertEqual(replayGainScalar(mode: .track, values: .empty, preampDB: 0), 1, accuracy: 0.000001)
}
```

Verify disabling/re-enabling EQ does not seek/reload/alter queue state.

- [ ] **Step 2: Run focused tests and confirm failures**

```bash
npm run test:ios -- -only-testing:AppTests/ReplayGainAndEQTests
```

- [ ] **Step 3: Implement metadata parsing + runtime application**

Read ReplayGain metadata from AVFoundation/common metadata when present. Keep the parser isolated so a future tag-reader adapter can supplement formats whose ReplayGain tags AVFoundation does not expose.

When a track becomes current/prepared, set per-slot gain before playback. Album mode uses album gain; track mode uses track gain; missing selected metadata yields unity. Peak values may create a diagnostic/headroom warning but never instantiate a limiter.

Migrate legacy JS EQ gain values once into the native 10-band model, then make native persistence authoritative.

- [ ] **Step 4: Run ReplayGain/EQ/coordinator/browser tests**

```bash
npm run test:ios -- -only-testing:AppTests/ReplayGainAndEQTests \
  -only-testing:AppTests/PlaybackCoordinatorTests
node test/native-audio-contract.mjs
npm run test:interface
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests app/index.html
git commit -m "feat(audio): add ReplayGain and native EQ controls"
```

---

### Task 12: Make 4.x library migration transactional and priority-aware

**Files:**
- Modify: `app/native-audio.js`
- Modify: `app/index.html`
- Modify: `ios/App/App/Audio/NativeAudioPlugin.swift`
- Modify: `ios/App/App/Audio/MediaStore.swift`
- Create: `ios/App/App/Audio/LibraryMigrationCoordinator.swift`
- Create: `ios/App/AppTests/LibraryMigrationTests.swift`
- Modify: `test/native-audio-contract.mjs`

**Interfaces:**
- Produces bridge methods:
  - `registerMediaReference({ trackID, path, relativePath, metadata })`
  - `beginMaterialization({ trackID, fileName, byteLength })` only for legacy blob-backed entries that lack a native file
  - `appendMaterializationChunk({ migrationID, sequence, base64 })`
  - `finishMaterialization({ migrationID })`
  - `migrationState()`

**Important constraint:** New imports must be written directly to native-accessible storage; chunked bridge materialization is a one-time compatibility path for legacy IndexedDB blobs only. Whole files must not be assembled in JS memory and sent in one bridge call.

- [ ] **Step 1: Write failing migration tests**

Native tests:
- partial migration does not mark track complete
- app restart resumes incomplete migration or safely discards only the `.partial` file
- verified final move marks migration complete atomically
- source reference is never deleted by migration
- missing file becomes `File unavailable`, not library deletion

JS contract test:
- requested/current album is migrated first
- chunks are bounded (for example 512 KiB) and sequenced
- native file-backed tracks register by reference instead of being copied through the bridge

- [ ] **Step 2: Run migration tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/LibraryMigrationTests
node test/native-audio-contract.mjs
```

- [ ] **Step 3: Implement priority-aware migration**

`LibraryMigrationCoordinator` state machine:

```text
unseen → referenced OR materializing(sequence N) → verifying → complete
                                             ↘ failed(recoverable)
```

For 4.x blob-backed media, JS streams fixed-size chunks only when the file is needed or during opportunistic migration. Native writes chunks directly to a `.partial` file and verifies with `MetadataProbe` before the atomic final move. The current requested queue gets priority; the rest of the library migrates opportunistically without blocking first launch.

- [ ] **Step 4: Run migration + library regressions**

```bash
npm run test:ios -- -only-testing:AppTests/LibraryMigrationTests \
  -only-testing:AppTests/MediaStoreTests
node test/native-audio-contract.mjs
npm run test:browser
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests app test/native-audio-contract.mjs
git commit -m "feat(audio): migrate legacy media transactionally"
```

---

### Task 13: Harden unsupported/corrupt/missing media and diagnostics UI

**Files:**
- Modify: `ios/App/App/Audio/MetadataProbe.swift`
- Modify: `ios/App/App/Audio/PlaybackCoordinator.swift`
- Modify: `ios/App/App/Audio/DiagnosticsLog.swift`
- Modify: `ios/App/App/Audio/NativeAudioPlugin.swift`
- Modify: `app/index.html`
- Modify: `app/interface.css`
- Modify: `ios/App/AppTests/MetadataProbeTests.swift`
- Modify: `ios/App/AppTests/PlaybackCoordinatorTests.swift`

**Interfaces:**
- Produces stable error codes:
  - `media_missing`
  - `format_unsupported`
  - `decode_failed`
  - `engine_failed`
  - `session_failed`
  - `migration_failed`
- Produces `getDiagnostics()` returning bounded sanitized entries.

- [ ] **Step 1: Add failing error-isolation tests**

Assert:
- corrupt current album track stops and explains; it does not silently skip
- missing file preserves `trackID`/library state and emits `mediaUnavailable`
- unsupported OGG/OPUS (if native decoder cannot open fixture) reports `format_unsupported`
- diagnostics redact absolute path while retaining internal track ID/extension/source format
- optional EQ failure bypasses EQ and continues only when transparent path initializes successfully

- [ ] **Step 2: Run failure tests and confirm failure**

```bash
npm run test:ios -- -only-testing:AppTests/MetadataProbeTests \
  -only-testing:AppTests/PlaybackCoordinatorTests
```

- [ ] **Step 3: Implement structured failures and restrained UI**

Native emits:

```json
{
  "code": "media_missing",
  "trackID": "...",
  "recoverable": true,
  "message": "File unavailable"
}
```

The player UI shows one compact on-theme error line near existing playback metadata. No modal technical dashboard is added. Diagnostics remain exportable/readable through the plugin for development/support.

- [ ] **Step 4: Run native + browser regressions**

```bash
npm run test:ios
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
node test/native-audio-contract.mjs
```

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Audio ios/App/AppTests app
git commit -m "fix(audio): isolate media failures and expose diagnostics"
```

---

### Task 14: Validate mixed-rate playback, background authority, and final 5.0 release behavior

**Files:**
- Modify/Create: `ios/App/AppTests/AudioIntegrationTests.swift`
- Modify: `test/fixtures/audio/generate-fixtures.py`
- Modify: `docs/releases/5.0.md`
- Create: `docs/validation/5.0-audio-device-matrix.md`
- Modify: `.github/workflows/ios-ipa.yml`
- Modify: `app/sw.js`

**Interfaces:**
- Consumes: complete native engine + JS adapter.
- Produces: CI-verifiable unsigned Aeon 5.0 IPA from a fresh Xcode compilation plus a physical-device validation checklist whose automated and manual evidence are explicitly separated.

- [ ] **Step 1: Add failing end-to-end integration assertions**

Automated suite must cover:
- `44.1 kHz → 96 kHz → 48 kHz` queue retains correct IDs/index/state while output descriptor updates
- seek to known marker stays within defined tolerance (start with ±20 ms for compressed/container paths; PCM fixture should be frame-accurate within scheduling API limits)
- native mode continues authoritative position updates when the WebView stops polling
- queue reorder invalidates old prepared-next item
- gapless WAV split still passes exact boundary test
- restored snapshot does not auto-play after cold process launch without valid resume intent/context

- [ ] **Step 2: Run the complete automated suite**

```bash
npm ci --no-audit --no-fund
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
node test/native-audio-contract.mjs
npm run test:ios
```

Expected: PASS before packaging.

- [ ] **Step 3: Update CI to compile a genuinely new native binary and unsigned IPA**

Workflow requirements:

```text
checkout
npm ci
all Node/Playwright tests
xcodebuild test
npx cap sync ios
xcodebuild App Release for generic/platform=iOS with signing disabled
package built App.app into Aeon-5.0-unsigned.ipa
upload artifact
```

Use a fresh Xcode-produced `App.app`; do **not** repackage the 4.6.1 binary.

Set `app/sw.js` cache to an Aeon 5.0 cache key.

- [ ] **Step 4: Execute and record the physical-device matrix**

On a real iPhone, fill `docs/validation/5.0-audio-device-matrix.md` with pass/fail, device/iOS version, route hardware, observed source/output rates, and notes for each required case:

```text
iPhone speaker
wired USB DAC
Bluetooth headphones
AirPods-class route
AirPlay
screen locked
app backgrounded
incoming interruption
wired output disconnect
Bluetooth output disconnect
Control Center play/pause/seek
hardware media controls
mixed-rate local album/queue
```

Do not mark a route behavior passed based on simulator behavior.

- [ ] **Step 5: Write release evidence and commit**

`docs/releases/5.0.md` must state:
- native engine architecture and scope
- exact automated suites/results
- physical-device matrix status
- format capability result for FLAC/ALAC/AAC/M4A/MP3/WAV/AIFF/CAF and explicit OGG/OPUS outcome
- ReplayGain/EQ defaults
- source-vs-output telemetry caveat
- any remaining known limitations

Then:

```bash
git add .github app ios test docs package.json package-lock.json
git commit -m "release: validate Aeon 5.0 native audio engine"
```

---

## Final Verification Gate

Before claiming Aeon 5.0 complete, run from a clean checkout on macOS/Xcode:

```bash
npm ci --no-audit --no-fund
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
node test/native-audio-contract.mjs
npm run test:ios
npx cap sync ios
xcodebuild -project ios/App/App.xcodeproj \
  -scheme App \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Then verify the packaged IPA:

```bash
unzip -t Aeon-5.0-unsigned.ipa
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Payload/App.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Payload/App.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Payload/App.app/Info.plist
```

Expected:

```text
app.isolation.sky
5.0
50 (or a monotonically higher final build number if intermediate native builds consumed 50)
```

Also compare the Aeon 5.0 app executable hash against 4.6.1: they **must differ**, because 5.0 contains new native Swift code. This is the inverse of the 4.x web-patch validation rule.

The release is not audio-complete until `docs/validation/5.0-audio-device-matrix.md` records physical-device results for every mandatory route/lifecycle case.
