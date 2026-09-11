# Aeon Native Audio Engine 5.0 — Design Specification

**Status:** Approved
**Date:** 2026-09-11
**Target release:** Aeon 5.0
**Current application baseline:** Aeon 4.6.1 / build 49, bundle `app.isolation.sky`, iOS 13 minimum, `UIBackgroundModes = [audio]`

## 1. Purpose

Aeon 5.0 replaces browser-owned playback with a native iOS audio subsystem while preserving the current Aeon visual interface, library model, constellation behavior, and navigation model.

The goal is not to add as many DSP features as possible. The goal is to create a transparent, dependable transport layer that behaves like a serious iOS music player under backgrounding, lock-screen control, route changes, interruptions, mixed sample rates, and continuous album playback.

The defining rule is:

> The web layer controls the experience. Native code owns playback truth.

Aeon 5.0 succeeds when the WebView can be suspended or absent and the native engine still maintains correct playback, queue timing, remote-control behavior, output state, and recovery.

## 2. Product principles

1. **Fidelity first.** No hidden limiter, compressor, exciter, bass enhancement, stereo widening, spatializer, or loudness enhancer.
2. **Transparent by default.** ReplayGain is optional. EQ is hard-bypassable and bypassed by default. Master gain defaults to unity.
3. **Native transport authority.** Once a track is loaded, native code is authoritative for play state, position, scheduling, output route, and engine state.
4. **Non-destructive library.** Aeon never alters source audio to apply ReplayGain, EQ, artwork changes, or analysis.
5. **Truthful telemetry.** Aeon distinguishes source format from actual negotiated output. It never labels playback “bit-perfect” unless that property can be demonstrated for the active path.
6. **Gapless means continuous.** “Gapless” is not merely a short pause; Aeon must avoid introducing artificial silence, duplicate audio, or avoidable boundary discontinuities.
7. **Failure isolation.** One corrupt file, route failure, or decoder failure must not crash the application or silently destroy library state.
8. **No UI rewrite during engine migration.** The existing Aeon UI remains intact for 5.0. A future native UI may consume the same engine interface without changing the engine.

## 3. Current-state constraint

Aeon 4.x uses browser playback. Its player is based on an HTML `<audio>` element feeding a Web Audio graph with a 10-band EQ, analyser, and gain stage. Existing 4.x releases have been packaged by replacing web assets inside a preserved unsigned Capacitor native shell.

Aeon 5.0 cannot use that packaging strategy as its primary build path. The native engine requires new Swift source, a Capacitor plugin, native project changes, and a fresh iOS compilation. The existing unsigned shell may remain useful as a visual/reference baseline, but 5.0 must be built from source.

## 4. High-level architecture

```text
Aeon HTML / CSS / JavaScript
library · playlists · sky · navigation · visual state
                    │
                    │ Capacitor bridge
                    ▼
             NativeAudioPlugin
                    │
                    ▼
            PlaybackCoordinator
        ┌───────────┼─────────────┐
        ▼           ▼             ▼
 QueueScheduler  MediaStore  AudioSessionController
        │           │             │
        ├───────────┼─────────────┤
        ▼           ▼             ▼
 MetadataProbe  StateStore  RemoteCommandCoordinator
        │
        ▼
              AVAudioEngine
        ┌───────────┴───────────┐
        ▼                       ▼
 AVAudioPlayerNode A     AVAudioPlayerNode B
        └───────────┬───────────┘
                    ▼
             ReplayGain stage
                    ▼
            AVAudioUnitEQ
          [bypassed by default]
                    ▼
              mainMixerNode
                    ▼
          Core Audio / iOS route
```

### 4.1 Ownership boundaries

**JavaScript owns:**
- library presentation and metadata model
- playlists and user-created organizational data
- constellation/world rendering
- navigation and sheets
- user commands and visual controls
- display of native telemetry

**Native owns:**
- loaded track and current queue index
- play/pause state and playback intent
- current playback position
- decode/open state
- gapless scheduling
- buffering/scheduling errors
- ReplayGain application
- native EQ state
- audio-session lifecycle
- actual output route and negotiated sample rate
- lock-screen / Control Center state
- interruption and route-change recovery
- crash-safe transport snapshot

JavaScript must not maintain an independent “shadow transport” that can diverge from the native engine. On foreground/reload, JS asks native for a complete authoritative snapshot and redraws from it.

## 5. Native component design

### 5.1 `NativeAudioPlugin`

A focused Capacitor plugin that exposes command methods and emits state events. It contains no significant playback policy; it delegates to `PlaybackCoordinator`.

Initial command surface:

```text
initialize()
load(trackID, mediaRef, queueContext?)
play()
pause()
toggle()
seek(seconds)
next()
previous()
setQueue(items, currentIndex)
updateQueue(items, currentIndex)
setVolume(linearOrDb)
setReplayGainMode(off | album | track)
setReplayGainPreamp(db)
setEQEnabled(bool)
setEQBands(bands)
getState()
getDiagnostics()
```

Initial event surface:

```text
stateChanged
positionChanged
trackChanged
queueChanged
routeChanged
formatChanged
interruptionChanged
engineRecovered
mediaUnavailable
playbackError
```

Events must carry monotonically increasing state/version identifiers so stale JS events cannot overwrite newer state after rapid skips, seeks, or app lifecycle transitions.

### 5.2 `PlaybackCoordinator`

Single source of transport policy. All commands from Aeon UI, `MPRemoteCommandCenter`, interruption recovery, and route recovery converge here.

Responsibilities:
- serialize state mutations
- validate requested transitions
- maintain playback intent separately from temporary engine state
- coordinate queue scheduling and seeking
- publish authoritative snapshots
- persist transport checkpoints
- prevent double starts and stale asynchronous completion callbacks

Implementation should use one explicit serialization domain: preferably a Swift actor where deployment constraints allow, otherwise a dedicated serial queue with strict confinement. Audio render callbacks must never perform blocking storage or bridge work.

### 5.3 `QueueScheduler`

Owns two `AVAudioPlayerNode` instances, A and B.

While one node renders the current track, the alternate node prepares the next eligible track. The scheduler owns:
- current and next file handles
- scheduled frame ranges
- end-of-track completion
- node handoff
- cancellation tokens for skips/seeks
- next-track invalidation when queue order changes

The purpose of two nodes is deterministic preparation and future extensibility, not simultaneous playback in 5.0. Except during a deliberately defined handoff boundary, only the intended program material may be audible.

### 5.4 `MediaStore`

Canonical native-access layer for imported audio that cannot safely remain browser/blob-backed.

Target location:

```text
Application Support/Aeon/Media/
```

MediaStore provides stable native file references independent of WebView blob URLs and JS object lifetime.

Rules:
- migration is transactional
- a source entry remains valid until the native copy is fully written and verified
- migration never deletes the source merely because a copy was attempted
- interrupted migrations resume safely
- duplicates are content/reference aware rather than blindly duplicated
- missing native files do not cause library entries to be silently deleted

External file-backed items may retain a stable original reference where iOS security-scoped access and application lifecycle make that safe; otherwise Aeon materializes them into MediaStore.

### 5.5 `MetadataProbe`

Inspects each native media item and returns a normalized descriptor:

```text
codec
container
sampleRate
channelCount
sourceBitDepth, where meaningful and available
duration
frameCount, where available
ReplayGain track gain
ReplayGain album gain
ReplayGain peak values, where available
decoder identifier / capability result
```

The UI must distinguish metadata that is known from metadata that is unavailable. Unknown bit depth must not be guessed.

### 5.6 `AudioSessionController`

Owns `AVAudioSession` configuration and lifecycle.

Base policy:

```text
category: .playback
mode: .default
mixing with other audio: off by default
```

It handles:
- activation/deactivation
- preferred sample-rate requests
- actual negotiated sample-rate observation
- interruption notifications
- route changes
- media-services reset/loss
- recovery requests into `PlaybackCoordinator`

A preferred sample rate is a request, not a guarantee. UI telemetry must report the actual session/output state after negotiation.

### 5.7 `RemoteCommandCoordinator`

Owns `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.

Supported commands:
- play
- pause
- next
- previous
- change playback position / scrub

It publishes:
- title
- artist
- album
- artwork
- elapsed time
- duration
- playback rate

Remote commands do not mutate player state independently. They call `PlaybackCoordinator`, exactly as UI commands do.

### 5.8 `PlaybackStateStore`

Maintains a small crash-safe native snapshot:

```text
trackID
queue IDs / queue revision
queue index
position
playback intent (playing | paused)
ReplayGain mode
ReplayGain preamp
master volume
EQ enabled/bands
last known route descriptor
snapshot timestamp/version
```

Actual playback should not auto-start after every process death merely because the previous snapshot said “playing.” Relaunch restoration must respect iOS lifecycle context and explicit user/remote intent. The snapshot exists to restore continuity, not create surprising playback.

### 5.9 `DiagnosticsLog`

Local rolling event log. No analytics upload.

Representative events:

```text
ENGINE_START
SOURCE_OPENED
OUTPUT_NEGOTIATED
NEXT_SCHEDULED
TRACK_HANDOFF
SEEK
ROUTE_CHANGE
INTERRUPTION_BEGIN
INTERRUPTION_END
ENGINE_REBUILD
MEDIA_SERVICES_RESET
DECODER_ERROR
PLAYBACK_STOPPED
```

Each entry includes timestamp, event code, relevant track ID, source/output formats, route, and recoverability where applicable. Avoid logging user-sensitive file paths when a stable internal ID suffices.

## 6. Audio graph and fidelity behavior

### 6.1 Default signal path

```text
decoder
  ↓
ReplayGain scalar [optional]
  ↓
AVAudioUnitEQ [bypassed by default]
  ↓
master gain
  ↓
main mixer
  ↓
output
```

Internal processing uses the native engine's floating-point PCM path. No claim is made that this is bit-identical to source bytes; the product promise is **no intentional coloration when optional processing is bypassed**.

### 6.2 ReplayGain

Modes:
- `off`
- `album`
- `track`

Default: `off` for maximum source-relative fidelity unless product settings explicitly change this before release.

`album` preserves the encoded loudness relationships of tracks within an album while applying album-level normalization metadata.

`track` applies individual track normalization and is appropriate for shuffle/mixed queues.

Preamp defaults to `0.0 dB`.

ReplayGain metadata is read when available. Aeon 5.0 does not block playback to perform loudness analysis for files without ReplayGain tags. Background analysis is a later 5.x feature.

If peak metadata indicates a requested gain may clip, the engine may expose a warning/headroom recommendation. It must not silently insert a limiter in 5.0.

### 6.3 EQ

Native EQ infrastructure exists in 5.0 but starts bypassed.

Requirements:
- hard bypass state is observable
- gain values persist
- enabling/disabling does not reset transport
- no hidden preset is active
- EQ implementation remains replaceable without changing plugin commands

The existing web 10-band EQ settings may be migrated to a matching native band model where practical, but transport correctness takes priority over perfect legacy EQ equivalence.

### 6.4 Source vs output telemetry

Aeon displays two different concepts:

**Source example**
```text
FLAC · 24-bit · 96 kHz
```

**Output example**
```text
PCM · 48 kHz · AirPods Pro
```

Output telemetry is based on actual native session/graph state, not an assumption from source metadata.

Bluetooth/AirPlay route labeling must avoid pretending that the application controls or can always infer every downstream codec detail. Show only information the platform exposes reliably.

### 6.5 Sample-rate policy

- request a source-appropriate session rate when useful and supported
- observe actual negotiated rate after activation/configuration
- avoid unnecessary application-level resampling
- allow Core Audio to perform unavoidable route conversion
- do not interrupt stable playback merely to chase an unavailable theoretical source rate
- rebuild/reconfigure cleanly when a new source family or output route requires it

Consecutive album tracks with compatible formats should remain on a stable graph configuration wherever possible.

## 7. Format strategy

Required 5.0 first-class targets:
- FLAC
- ALAC
- AAC / M4A
- MP3
- WAV
- AIFF
- CAF

Existing Aeon import logic also recognizes OGG and OPUS. Native 5.0 must not silently discard these entries. During implementation, `MetadataProbe`/decoder capability tests determine whether the system decoder can open the exact containers present in fixtures. If not, one of two explicit outcomes is required before release:

1. add a narrowly scoped native decoder adapter for the unsupported container/codec, or
2. retain the library entry and surface a clear “format not supported by this engine” state while preserving the file.

No unsupported format may be silently converted, deleted, or reported as successfully playable.

Decoder-specific code sits behind a small interface so adding a future codec does not alter queue/session logic.

## 8. Gapless playback contract

Aeon defines gapless playback as:

> No artificial silence, duplicate program material, or avoidable boundary discontinuity introduced between consecutive queue items that are intended to be continuous.

For compatible local files:
- next track is opened before current track completion
- its node is scheduled before the current boundary
- the handoff occurs without waiting for JS, file-picker work, UI timers, or a new bridge request

Compressed formats may contain encoder delay/padding. The implementation must respect decoder/container timing rather than assuming nominal file duration is a perfect PCM boundary.

### 8.1 Gapless regression fixture

Create a continuous deterministic waveform, split it into multiple encoded tracks, play them through the native engine, and capture/inspect the output path available to tests.

The test fails if the reconstructed transition contains:
- inserted silence above the defined tolerance
- duplicated samples/program section
- a boundary discontinuity not present in the expected decode

The implementation plan must define measurable tolerances per fixture/codec rather than relying on subjective listening alone.

## 9. Route and interruption behavior

### 9.1 Interruptions

On interruption begin:
1. snapshot transport
2. stop/suspend scheduling safely
3. retain user playback intent separately from temporary interruption state

On interruption end:
- resume only when system resumption semantics and prior user intent both permit it
- if user was paused before interruption, remain paused

### 9.2 Output removal

Safety policy:
- wired headphones removed → pause
- Bluetooth output disappears → pause
- USB DAC removed → pause and rebuild for the new route; do not unexpectedly blast through the speaker

A newly connected route may trigger graph/session reconfiguration. Continuation is allowed only when it is safe and consistent with current playback intent.

### 9.3 AirPlay / Bluetooth / USB

Each route change emits a normalized route descriptor. Native state includes at minimum:
- route class
- human-readable route name where available
- actual session sample rate
- channel count where available

Do not infer unsupported technical details merely for a richer badge.

## 10. Recovery model

Engine/session invalidation is treated as normal lifecycle behavior, not an exceptional crash path.

Recovery hierarchy:

**Level 1 — node recovery**
- recreate/reschedule the affected player node

**Level 2 — engine recovery**
- stop graph
- recreate/reconnect nodes
- reopen current media
- seek to checkpoint
- schedule next track
- resume if intent is playing

**Level 3 — session recovery**
- reactivate/reconfigure `AVAudioSession`
- rebuild engine
- restore transport snapshot
- resume only if policy permits

Retries are bounded. If recovery fails, Aeon stops safely and emits a structured error. It must not enter an infinite restart loop while a playhead silently advances.

## 11. Media migration

Migration from the 4.x library must be incremental and recoverable.

For each track:
1. resolve current Aeon source representation
2. determine whether native already has a stable accessible file
3. materialize into MediaStore if required
4. verify write/openability and expected basic metadata
5. write/update native media reference
6. mark migration complete
7. leave original source untouched until completion is durable

If the app exits halfway through, completed tracks remain completed and incomplete tracks retry later.

Migration should not block the whole application behind an all-or-nothing first-launch screen. It may prioritize the requested album/queue and continue remaining work opportunistically.

## 12. UI integration behavior

The Aeon 4.6.1 visual language remains the baseline.

For 5.0, UI changes should be limited to controls and telemetry necessary to expose the engine cleanly:
- source format
- actual output format / route
- ReplayGain mode
- EQ bypass/enabled status
- recoverable playback errors

No new generic dashboard, pill-heavy settings design, or large technical panel is required. Advanced information should reveal on demand and remain subordinate to listening.

The web player must stop directly owning audio once native transport is active. A development/fallback web engine may exist behind an explicit platform/feature flag for browser test environments, but it must not compete with native transport on iOS.

## 13. Testing strategy

### 13.1 Unit tests

Native unit coverage for:
- state-machine transitions
- stale command/event rejection
- queue revisions
- ReplayGain math
- EQ serialization/bypass state
- migration state machine
- metadata normalization
- route policy decisions
- interruption policy decisions
- bounded recovery logic

### 13.2 Audio integration tests

Fixtures for:
- gapless continuous waveform
- known-duration seeking
- ReplayGain expected scalar
- mixed sample rates (`44.1 → 96 → 48 kHz`)
- queue skip/reorder while next node is pre-scheduled
- corrupt/truncated media
- missing media file
- format capability checks

### 13.3 JS ↔ native contract tests

Validate:
- plugin commands map to one native action
- event versions are monotonic
- reconnect/foreground requests a full snapshot
- stale events cannot regress UI state
- queue changes invalidate obsolete native scheduling

### 13.4 Existing Aeon regressions

Retain existing browser/interface/library regression coverage where applicable. Adapt browser tests to a mock NativeAudio bridge instead of requiring native audio in Playwright.

### 13.5 Physical-device release matrix

Automated tests are not sufficient for audio completion. Physical iPhone validation must cover at least:

- iPhone speaker
- wired USB audio / DAC
- Bluetooth headphones
- AirPods-class Bluetooth route
- AirPlay
- screen locked
- app backgrounded
- incoming interruption
- wired output disconnect
- Bluetooth output disconnect
- Control Center play/pause/seek
- hardware media controls
- mixed-rate local album/queue

The release report must explicitly separate automated evidence from physical-device evidence.

## 14. Failure handling

### 14.1 Corrupt/undecodable track

- emit structured `mediaUnavailable` or `playbackError`
- preserve library item
- do not crash queue engine
- next-step behavior is explicit: stop for direct album play if continuity cannot be guaranteed, or allow user-configured/defined skip behavior later

For 5.0, default to **stop and explain** rather than silently skipping a potentially important album track.

### 14.2 Missing file

Show `File unavailable`. Preserve metadata/library position. Offer repair/relink later; do not auto-delete.

### 14.3 DSP failure

If optional EQ cannot initialize, bypass it and continue only if the transparent path is safe. Surface the failure diagnostically. ReplayGain math is simple gain staging and should not depend on an optional DSP unit.

### 14.4 State corruption

Transport snapshots are versioned. Invalid/incompatible state is rejected and playback falls back to a safe stopped state without mutating the user's library.

## 15. Versioning and build implications

This subsystem defines **Aeon 5.0**, not a 4.6.x web patch.

Required build changes:
- fresh Xcode/native compilation
- Swift native source included in the repository
- Capacitor plugin registered with the application
- native unit/integration test target(s)
- existing bundle identifier remains `app.isolation.sky` unless explicitly changed later
- background audio entitlement/mode retained
- deployment floor remains iOS 13 only if every selected implementation primitive and dependency supports it; otherwise any increase requires an explicit product decision before implementation

The old “replace only web assets inside the unsigned native shell” packager is insufficient for 5.0 native-engine development.

## 16. Explicitly deferred from 5.0

- crossfade
- limiter
- loudness analysis for files with no ReplayGain metadata
- headphone correction profiles
- convolution
- spatialization
- stereo enhancement
- AUv3 hosting
- streaming-service integrations
- user-facing DSP laboratory
- full SwiftUI player rewrite

The dual-node graph and clean native interface should make crossfade and headphone/DSP profiles feasible in later 5.x releases without replacing transport architecture.

## 17. Acceptance criteria

Aeon 5.0 audio-engine work is complete only when all of the following are true:

1. iOS playback no longer depends on HTML `<audio>` timing for native mode.
2. Native transport remains correct with the WebView backgrounded/suspended.
3. Gapless fixtures meet defined measurable transition tolerances.
4. ReplayGain Off/Album/Track is deterministic and tested.
5. EQ is bypassed by default and transparent-path behavior is verified as far as the platform/test path permits.
6. Lock-screen and Control Center commands control the same authoritative transport as the app UI.
7. Wired/Bluetooth/USB route-loss safety policies work on physical hardware.
8. Interruption recovery respects both iOS resumption semantics and prior user intent.
9. Source and output telemetry are distinct and truthful.
10. Existing library migration is transactional and does not destroy source files.
11. Corrupt/missing/unsupported media cannot crash the application or silently remove library entries.
12. Automated and physical-device validation evidence are reported separately.
13. The existing Aeon UI, library, queue semantics, and constellation experience remain intact except where the native transport contract requires deliberate adaptation.

## 18. Implementation-order constraint

Implementation planning should prioritize a vertically working transparent transport before feature breadth:

1. native plugin contract + state model
2. MediaStore/native file access
3. single-track native decode/play/pause/seek
4. authoritative state + JS integration
5. dual-node queue/gapless scheduling
6. background/session/remote commands
7. interruption/route/recovery
8. ReplayGain
9. native EQ/bypass
10. telemetry/diagnostics
11. migration hardening and full validation

No crossfade, headphone profile, or advanced DSP work begins until this transport passes its core native and physical-device gates.

## 19. Baseline evidence used for this design

The current packaged baseline is Aeon 4.6.1 build 49 with bundle identifier `app.isolation.sky`, minimum iOS 13.0, and background audio mode enabled. The 4.x source history records browser playback as `<audio> → 10× BiquadFilter → analyser → gain → out`, and prior release packaging preserved the native executable/frameworks while replacing web assets. Existing import handling recognizes common audio types including FLAC, OGG, and OPUS. These constraints are why 5.0 is defined as a fresh native build rather than another web-asset-only revision.
