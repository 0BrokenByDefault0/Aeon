# Aeon 5.0 Native SwiftUI Rebuild Plan

**Date:** 2026-09-13  
**Branch:** `feat/native-audio-5.0`  
**Design authority:** `docs/handoffs/claude-swiftui-design-handoff.md`  
**Audio foundation:** Tasks 1 through 7 of `docs/superpowers/plans/2026-09-11-aeon-native-audio-engine.md`

## Outcome

Aeon 5.0 is an iPhone/iPad application whose visible interface is SwiftUI, whose sky is rendered by Metal, and whose playback is owned by the existing native `AVAudioEngine` stack. The current HTML application remains a behavioral oracle and a migration reader only. It is never embedded as a visible screen in the finished interface.

The cutover order is data safety first, then native domain and playback integration, then the sky and SwiftUI surfaces, then removal of obsolete web ownership. An installed 4.x library must survive an in-place upgrade with the same bundle identifier. No legacy record, audio file, artwork blob, playlist, play count, setting, queue checkpoint, or sky seed is deleted during migration.

This plan supersedes Tasks 8 through 14 of the 2026-09-11 native-audio plan. Tasks 1 through 7 are complete and remain the playback foundation.

## Locked product decisions

These resolve the handoff's open list unless Clayton explicitly changes one later:

1. **Planet interval is 20 albums.** Cohorts are albums 1–20, 21–40, and so on in immutable import order. A planet forms when its twentieth member arrives. Existing libraries backfill by the same rule. The legacy HTML's `PER_WORLD = 50` remains historical behavior only and is not ported.
2. **Aeon Nocturne is the display face.** Do not wait for or reference the missing Arthemys asset in native code. Ship the OTF plus the existing GUST/LPPL license and provenance files.
3. **EQ and Spectrum live in Now Playing.** Settings contains their defaults and reset controls, not the primary controls.
4. **iPad is first-class.** It gets persistent sidebar navigation, a wider library, side-panel album detail, and an optional Now Playing detail pane.
5. **iPhone landscape is supported.** It uses a compact two-column arrangement where width permits; it is not orientation-locked.
6. **The library must tolerate messy, large collections.** Ten-thousand-file folder import, Uncharted, deterministic fallback grouping, resumable work, and bounded memory are release requirements.
7. **Planet naming and every item under handoff §22 remain post-5.0.** Default planet labels use `AEON-001`, `AEON-002`, and so on. There is no rename UI in 5.0.
8. **Destructive copy is fixed:** `Delete Album? This removes it from Aeon. Files you added through Files stay on this device.` The destructive button is `Delete Album`. `Erase Everything? This removes Aeon’s catalogue, artwork, playlists, listening history, and copied audio from this device. Files Aeon adopted in place are not deleted.` The destructive button is `Erase Everything` and requires typing `ERASE`.
9. **Minimum OS is iOS/iPadOS 16.0.** This permits one native navigation implementation without backport scaffolding. Device families remain iPhone and iPad only; Mac Catalyst and visionOS are excluded.

## Non-negotiable engineering constraints

- Keep `app.isolation.sky` unchanged so the app update sees the existing container and WKWebView data store.
- Keep `Documents/Music` as the canonical user-visible audio root. Existing path-backed 4.x tracks are adopted in place and never duplicated merely to fit a new directory scheme.
- Store the native catalogue, artwork cache, diagnostics, and transport checkpoints under `Application Support/Aeon`.
- Use SQLite through the system `SQLite3` library. No ORM and no new database dependency.
- Keep Capacitor linked only for the hidden one-time IndexedDB migration bridge in 5.0. The app's root, navigation, player, importers, settings, and sky are native.
- Never make a network lookup necessary to place, browse, import, or play music. MusicBrainz then Apple remains an explicit opt-in enrichment path.
- Store stable IDs, import sequence, timestamps, star coordinates, planet membership, planet frontier radius, and derived seeds. Never infer them again after a successful migration.
- Use bounded page sizes and file streaming. No entire library, archive, audio file, or artwork collection may be materialized in memory.
- Preserve the current browser and Node suites as regression oracles until feature parity is signed off. Native behavior gets XCTest/XCUITest coverage rather than DOM tests.
- Do not remove the 4.x web assets or clear IndexedDB in 5.0. Removal is a later compatibility decision after shipped migrations are proven.
- No emoji, dashed borders, numbered tabs, stock SwiftUI `Material`, generic rounded-card chrome, or decorative gradient palette.

## Native structure

Create these modules inside the existing application target; do not create framework targets until build time proves one is necessary:

```text
ios/App/App/
  AeonApp.swift
  AppContainer.swift
  AppDelegate.swift
  Domain/
    Album.swift
    Track.swift
    Artist.swift
    Playlist.swift
    LibrarySettings.swift
    ListeningStats.swift
  Persistence/
    CatalogDatabase.swift
    CatalogSchema.swift
    CatalogRepository.swift
    CatalogMigrations.swift
    ArtworkStore.swift
  Migration/
    LegacyMigrationModels.swift
    LegacyMigrationCoordinator.swift
    LegacyMigrationPlugin.swift
    LegacyMigrationViewController.swift
  Import/
    LibraryImporter.swift
    AudioTagReader.swift
    ImportGrouper.swift
    ArtworkProcessor.swift
    ArchiveReader.swift
    ArchiveWriter.swift
  Sky/
    SkyModels.swift
    SkyComposer.swift
    SkyRepository.swift
    PlanetTextureGenerator.swift
    Metal/
      SkyRenderer.swift
      SkyMetalView.swift
      SkyShaders.metal
  Playback/
    PlaybackController.swift
    AudioSessionController.swift
    RemoteCommandCoordinator.swift
    RecoveryCoordinator.swift
    SpectrumAnalyzer.swift
  DesignSystem/
    AeonTheme.swift
    AeonTypography.swift
    AeonGlass.swift
    AeonControls.swift
    AeonArtwork.swift
    AeonChrome.swift
  Features/
    Root/AeonRootView.swift
    Sky/SkyScreen.swift
    Library/LibraryScreen.swift
    Library/AlbumDetailView.swift
    Library/AlbumEditorView.swift
    Player/PlayerBar.swift
    Player/NowPlayingView.swift
    Player/QueueView.swift
    Player/EQView.swift
    Playlists/PlaylistsScreen.swift
    Settings/SettingsScreen.swift
    Migration/MigrationScreen.swift
  Resources/
    AeonNocturne-Regular.otf
    GUST-FONT-LICENSE.txt
    LPPL-1.3c.tex
```

`AppContainer` is the sole composition root. It owns one `CatalogRepository`, `MediaStore`, `PlaybackCoordinator`, `PlaybackController`, `AudioSessionController`, `RemoteCommandCoordinator`, `LegacyMigrationCoordinator`, and `SkyRepository`. Feature views receive observable controllers or narrow protocols; they do not open SQLite, resolve URLs, or mutate the audio graph directly.

## Catalogue schema v1

Use explicit migrations and `PRAGMA user_version`. Enable foreign keys and WAL mode. Every schema change is covered by an upgrade test.

```text
albums(id PK, import_sequence UNIQUE, imported_at, title, album_artist,
       year, genre, artwork_key, is_compilation, created_at, updated_at)
tracks(id PK, album_id FK, disc_number, track_number, title, artist,
       duration, file_extension, media_kind, media_path, media_ownership,
       byte_count,
       replaygain_track_db, replaygain_album_db, track_peak, album_peak,
       bpm, dynamic_range, created_at, updated_at)
playlists(id PK, name, created_at, updated_at)
playlist_items(playlist_id FK, position, album_id FK, track_id FK,
               PRIMARY KEY(playlist_id, position))
listening(album_id PK FK, play_count, completed_count, seconds_played,
          last_played_at)
settings(key PK, json_value)
lookup_cache(artist_key PK, canonical_genre, source, resolved_at)
sky_stars(album_id PK FK, region_key, x, y, magnitude, placed_at,
          placement_version)
planets(id PK, planet_index UNIQUE, label, frontier_radius, seed,
        formed_at, descriptor_json)
planet_albums(planet_id FK, position, album_id FK,
              imported_at, PRIMARY KEY(planet_id, position))
migration_runs(id PK, source_version, status, counts_json, cursor_json,
               started_at, updated_at, completed_at, error_code)
migration_artifacts(id PK, run_id FK, owner_id, kind, expected_bytes,
                    expected_crc32, received_bytes, status, relative_path)
```

`media_kind` is one of `documents`, `externalBookmark`, or `legacyBlob`. `documents` paths are relative to the app's Documents directory and must remain inside it after canonicalization. `media_ownership` distinguishes Aeon-copied files from user-adopted files. `legacyBlob` is retained only until its IndexedDB blob has been verified and atomically materialized.

## Definition of done

Aeon 5.0 is complete only when all automated gates pass, the physical-device audio matrix is filled with actual device evidence, the in-place 4.x upgrade fixture migrates without loss, the SwiftUI screen matrix is reviewed against Claude's handoff, and an unsigned IPA is produced from a fresh native compilation. Simulator evidence cannot close a physical route, background, interruption, or lock-screen requirement.

---

### Task 8: Prove access to the installed 4.x data store before replacing the root UI

**Files**

- Create `app/legacy-migration.html`
- Create `app/legacy-migration.js`
- Create `ios/App/App/Migration/LegacyMigrationViewController.swift`
- Create `ios/App/App/Migration/LegacyMigrationPlugin.swift`
- Create `ios/App/AppTests/LegacyDataAccessTests.swift`
- Create `test/legacy-migration-contract.mjs`

**Produces**

- A migration-only `CAPBridgeViewController` whose `instanceDescriptor().appStartPath` is `legacy-migration.html`.
- A paged, read-only inventory of IndexedDB `isolation-db` v1.
- Upgrade proof that the existing `capacitor://localhost` website data store is visible to the new binary.

- [x] Add contract tests that seed albums, tracks, playlists, and `kv`, load the migration page, and assert exact counts and stable IDs without loading the main UI.
- [x] Add a native test seam around the plugin callbacks and reject unknown stores, malformed records, duplicate page numbers, absolute paths, `..`, negative sizes, and pages larger than 250 records.
- [x] Override only `appStartPath`; retain the default `WKWebsiteDataStore` and the same scheme/host. Register only `LegacyMigrationPlugin` in this controller.
- [x] Make the page enumerate `albums`, `tracks`, `playlists`, and `kv` through readonly transactions. Strip `Blob` fields from record pages and describe each blob separately by owner, type, size, and filename.
- [x] Seed two path-backed tracks and one blob-backed track in the running simulator app, then prove a second migration-only controller reads the exact same `capacitor://localhost` data store and records.
- [ ] Repeat the installed-upgrade fixture on a physical iPhone before release: install 4.x, seed the mixed backing-store library, terminate, install 5.0 over it, and compare exact records.
- [x] Confirm the bridge never calls `deleteDatabase`, `clear`, `delete`, `put`, `add`, or a readwrite transaction.

**Gate**

```bash
node test/legacy-migration-contract.mjs
npm run test:ios -- -only-testing:AppTests/LegacyDataAccessTests
```

**Commit:** `test(migration): prove access to installed legacy libraries`

---

### Task 9: Establish the native application shell and composition root

**Files**

- Create `ios/App/App/AeonApp.swift`
- Create `ios/App/App/AppContainer.swift`
- Create `ios/App/App/Features/Root/AeonRootView.swift`
- Modify `ios/App/App/AppDelegate.swift`
- Modify `ios/App/App/Info.plist`
- Modify `ios/App/App.xcodeproj/project.pbxproj`
- Create `ios/App/AppTests/AppContainerTests.swift`

**Produces**

- SwiftUI `@main` lifecycle with an `UIApplicationDelegateAdaptor` only for application callbacks.
- Injectable production and in-memory test containers.
- A temporary native launch state that can show migration, ready, or fatal-recovery states.

- [x] Write tests asserting each production service is created once, test containers use temporary roots, startup failure produces a recoverable state, and no feature view constructs service singletons.
- [x] Remove `@UIApplicationMain` from `AppDelegate`; remove `UIMainStoryboardFile`; retain `LaunchScreen.storyboard`.
- [x] Raise app/test/pod deployment targets to 16.0, keep `TARGETED_DEVICE_FAMILY = "1,2"`, keep the bundle identifier, and explicitly disable Catalyst. Add an `AppUITests` target and shared scheme entries for the screen and interaction suites introduced later.
- [x] Move eager `AVAudioSession` activation out of `AppDelegate`; the audio session controller activates on a playback request and handles errors.
- [x] Make `AeonRootView` a black native surface with launch/migration states. Do not reproduce feature UI yet.
- [x] Embed `LegacyMigrationViewController` only while catalogue migration or legacy-blob materialization work exists. It sits behind opaque SwiftUI UI and is removed from the view tree only when no `legacyBlob` record remains.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/AppContainerTests \
  -only-testing:AppTests/SmokeTests
```

**Commit:** `feat(app): establish native SwiftUI lifecycle`

---

### Task 10: Implement the transactional SQLite catalogue

**Files**

- Create `ios/App/App/Domain/*.swift`
- Create `ios/App/App/Persistence/CatalogDatabase.swift`
- Create `ios/App/App/Persistence/CatalogSchema.swift`
- Create `ios/App/App/Persistence/CatalogRepository.swift`
- Create `ios/App/App/Persistence/CatalogMigrations.swift`
- Create `ios/App/App/Persistence/ArtworkStore.swift`
- Create `ios/App/AppTests/CatalogDatabaseTests.swift`
- Create `ios/App/AppTests/CatalogRepositoryTests.swift`

**Produces**

- Typed catalogue models independent of UI and SQLite row objects.
- Transactional CRUD, search, playlist ordering, listening updates, settings, sky records, and migration staging.
- Async observation snapshots delivered on the main actor without exposing database handles.

- [x] Write schema tests for fresh creation, foreign keys, indices, WAL, rollback, corrupt database quarantine, and migration from every checked-in schema fixture.
- [x] Write repository tests for deterministic album order, natural track order, duplicate stable IDs, playlist referential integrity, normalized search, play-count monotonicity, and one-transaction album deletion.
- [x] Implement a small prepared-statement wrapper with bound values only. No interpolated user strings in SQL.
- [x] Link the system `libsqlite3.tbd` and keep all SQLite C handles private to `CatalogDatabase`.
- [x] Serialize writes through one database queue. Reads use bounded result pages; library grid queries never hydrate track rows or artwork bytes.
- [x] Keep artwork as validated HEIF/JPEG files in `Application Support/Aeon/Artwork`; store only keys in SQLite. Write to `.partial`, decode, downsample, fsync, then atomically replace.
- [x] On open failure, move only the damaged database and WAL/SHM siblings to a timestamped `Recovery` directory. Never touch media or IndexedDB. Surface restore/retry choices in startup state.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/CatalogDatabaseTests \
  -only-testing:AppTests/CatalogRepositoryTests
```

**Commit:** `feat(library): add native transactional catalogue`

---

### Task 11: Migrate the 4.x catalogue, artwork, and blob media without loss

**Files**

- Create `ios/App/App/Migration/LegacyMigrationModels.swift`
- Create `ios/App/App/Migration/LegacyMigrationCoordinator.swift`
- Modify `ios/App/App/Migration/LegacyMigrationPlugin.swift`
- Modify `app/legacy-migration.js`
- Modify `ios/App/App/Audio/MediaStore.swift`
- Modify `ios/App/App/Audio/PlaybackModels.swift`
- Create `ios/App/AppTests/LegacyMigrationTests.swift`
- Extend `test/legacy-migration-contract.mjs`

**Produces**

- Idempotent catalogue import from IndexedDB.
- In-place registration of `Documents/Music` tracks.
- Resumable 512 KiB artwork/audio blob materialization with CRC32 and native media validation.

- [x] Add tests for exact field mapping of albums, tracks, playlists, `seq`, `plays`, `log`, `settings`, `skySeed`, and `lastPlayed`; preserve unknown future `kv` entries in a namespaced JSON record.
- [x] Add tests proving path-backed tracks are not copied, adopted files are never deleted, traversal is rejected, missing files remain catalogued as unavailable, and source IndexedDB remains unchanged.
- [x] Add tests for interruption after every migration state: inventory, staged rows, artifact chunk N, artifact verification, catalogue publication, and final marker. Relaunch must resume or safely retry without duplicate rows.
- [x] Extend media resolution so `.documents(relativePath:)` resolves beneath the app Documents root. Migrate existing `Music/...` paths to that case. Keep `.legacyBlob(trackID:)` until native materialization succeeds.
- [x] Stage catalogue rows under a migration run, validate record counts/references, then publish them in one transaction. A failed run is invisible to the normal repository.
- [x] Stream artwork first. Stream blob audio only when requested for playback or during bounded background work; prioritize the current queue. Each chunk carries run ID, artifact ID, sequence, and CRC state.
- [x] Write blob media under `Documents/Music/_Migrated/.incoming`; verify byte count, CRC32, and `MetadataProbe`, then move atomically to the final extension-preserving path and update `media_kind` in one transaction.
- [x] Mark the catalogue `ready` only after publication and artwork completion. Mark the legacy source `complete` only when no `legacyBlob` record remains; the hidden bridge stays available between those states.
- [x] Provide SwiftUI progress, retry, diagnostics export, and `Continue with available files` actions. Never offer erase as migration recovery.

**Gate**

```bash
node test/legacy-migration-contract.mjs
npm run test:ios -- -only-testing:AppTests/LegacyMigrationTests \
  -only-testing:AppTests/MediaStoreTests
```

Repeat the installed-upgrade fixture from Task 8 and compare pre/post manifests by album ID, track ID, playlist position, byte size, and CRC32.

**Commit:** `feat(migration): preserve legacy libraries in native storage`

---

### Task 12: Build the native importer, tag reader, artwork pipeline, and enrichment cache

**Files**

- Create `ios/App/App/Import/LibraryImporter.swift`
- Create `ios/App/App/Import/AudioTagReader.swift`
- Create `ios/App/App/Import/ImportGrouper.swift`
- Create `ios/App/App/Import/ArtworkProcessor.swift`
- Create `ios/App/App/Import/MetadataEnricher.swift`
- Modify `ios/App/App/Audio/MetadataProbe.swift`
- Create `ios/App/AppTests/LibraryImporterTests.swift`
- Create `ios/App/AppTests/AudioTagReaderTests.swift`
- Create `ios/App/AppTests/MetadataEnricherTests.swift`

**Produces**

- Native file and folder import through the Files picker.
- Bounded metadata/artwork extraction for MP3, M4A/AAC/ALAC, FLAC, WAV, AIFF, and CAF.
- Existing `single`, `folder`, and `smart` grouping semantics in testable Swift.
- Opt-in MusicBrainz-first, Apple-second artist genre enrichment with permanent cache entries.

- [ ] Port the existing filename natural ordering, disc/track inference, normalized person/album keys, majority-field selection, duplicate-album rule, and grouping fixtures into native tests before implementation.
- [ ] Add fixture tests for Unicode, punctuation, multi-disc numbering, vinyl sides, missing tags, corrupt art, oversized art, compilations, repeated album names by different artists, and partial import failure.
- [ ] Read files incrementally with `AVURLAsset`/`AVMetadataItem` and `AVAudioFile`; supplement format-specific gaps with bounded ID3, MP4 atom, and FLAC block readers only where fixtures prove AVFoundation loses required fields. Never load audio payloads to parse tags.
- [ ] Normalize embedded or selected art by decoding once, fixing orientation, downsampling to the configured maximum, and writing through `ArtworkStore`. A bad image becomes the celestial placeholder, not a failed album import.
- [ ] Present SwiftUI-wrapped document pickers for individual files and folders. Copy external files into `Documents/Music` through `.incoming`; adopt a file already under `Documents/Music` without copying it.
- [ ] Make scans cancellable between files and resumable from a persisted cursor. Commit one complete album per transaction; if no track for an album verifies, publish no album shell.
- [ ] Bound concurrent probes and artwork decodes. A 10,000-file fixture must show stable memory rather than work proportional to total library size.
- [ ] Keep lookup off by default. Cache a successful canonical artist genre once; do not retry it automatically or move existing stars after later network responses. Manual `LOOK UP` can explicitly replace the cached answer and invokes the star-move confirmation.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/LibraryImporterTests \
  -only-testing:AppTests/AudioTagReaderTests \
  -only-testing:AppTests/MetadataEnricherTests \
  -only-testing:AppTests/MetadataProbeTests
```

**Commit:** `feat(library): import local collections natively`

---

### Task 13: Connect SwiftUI directly to playback, audio sessions, remote commands, recovery, and ReplayGain

**Files**

- Create `ios/App/App/Playback/PlaybackController.swift`
- Create `ios/App/App/Playback/AudioSessionController.swift`
- Create `ios/App/App/Playback/RemoteCommandCoordinator.swift`
- Create `ios/App/App/Playback/RecoveryCoordinator.swift`
- Modify `ios/App/App/Audio/PlaybackCoordinator.swift`
- Modify `ios/App/App/Audio/AudioEngineGraph.swift`
- Modify `ios/App/App/Audio/ReplayGain.swift`
- Modify `ios/App/App/Audio/MetadataProbe.swift`
- Create `ios/App/AppTests/PlaybackControllerTests.swift`
- Create `ios/App/AppTests/AudioSessionPolicyTests.swift`
- Create `ios/App/AppTests/RecoveryTests.swift`
- Extend `ios/App/AppTests/ReplayGainAndEQTests.swift`

**Produces**

- A `@MainActor ObservableObject` that maps authoritative playback snapshots to SwiftUI.
- Background playback and lock-screen/Control Center commands.
- Bounded node → engine → session recovery.
- Per-track/album ReplayGain and persistent native EQ without browser audio ownership.

- [ ] Test that SwiftUI state follows snapshot versions, stale callbacks cannot roll state backward, playback failures stay inline, and app foreground requests a fresh snapshot.
- [ ] Test route-loss and interruption policy as pure functions: unplugging wired/USB/Bluetooth output pauses before speaker fallback; an interruption resumes only when both system policy and user intent allow it.
- [ ] Move `AVAudioSession` category/activation into `AudioSessionController`. Observe interruption, route change, media services lost/reset, and silence-secondary-audio hints. Notification callbacks enqueue normalized events into `PlaybackCoordinator`.
- [ ] Implement `RemoteCommandCoordinator` so every command calls the coordinator, never the engine. Publish title, artist, album, artwork, duration, elapsed time, rate, queue position, and actual route from catalogue plus snapshots.
- [ ] Implement recovery checkpoints and exactly three escalation levels: reschedule nodes, rebuild graph, then reactivate session and rebuild. Stop safely after level three. Resume only if the stored user intent is playing.
- [ ] Build `OutputFormatDescriptor` from actual session and graph values after activation/rebuild. Do not claim Bluetooth/AirPlay codecs the platform does not expose.
- [ ] Parse ReplayGain values where available; album mode uses album gain, track mode uses track gain, missing data is unity. Apply gain to each prepared slot before playback. Peak values create a warning only; do not add a limiter.
- [ ] Make `PlaybackController` the `PlaybackCoordinatorDelegate`. Retire `NativeAudioPlugin` from normal app composition; keep its source and contract tests until the migration-only Capacitor dependency can be removed after 5.0.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/PlaybackControllerTests \
  -only-testing:AppTests/AudioSessionPolicyTests \
  -only-testing:AppTests/RecoveryTests \
  -only-testing:AppTests/ReplayGainAndEQTests \
  -only-testing:AppTests/PlaybackCoordinatorTests
```

**Commit:** `feat(audio): integrate native playback with SwiftUI`

---

### Task 14: Persist the sky grammar and deterministic planet model

**Files**

- Create `ios/App/App/Sky/SkyModels.swift`
- Create `ios/App/App/Sky/SkyComposer.swift`
- Create `ios/App/App/Sky/SkyRepository.swift`
- Create `ios/App/App/Sky/PlanetTextureGenerator.swift`
- Create `ios/App/AppTests/SkyComposerTests.swift`
- Create `ios/App/AppTests/PlanetModelTests.swift`
- Create `ios/App/AppTests/Fixtures/sky-catalogue-v1.json`

**Produces**

- Stable star, constellation, VA cluster, genre region, Uncharted, and planet records.
- Deterministic backfill and incremental placement with permanent coordinates.
- Fixed-output planet descriptors and textures derived from immutable album cohorts.

- [ ] Lock the grammar in tests: one album is one star; artists get figure lines only at two or more albums; Various Artists gets no figure; no usable genre becomes Uncharted; local majority ties go to the earliest imported album.
- [ ] Test placement precedence exactly as the handoff specifies. Network-off results must be identical across launches and devices.
- [ ] Persist a star coordinate at first placement. Rebuild, import, playback, migration, lookup-cache refresh, rotation, and renderer changes must not alter it. Only confirmed charting/manual metadata edits may generate a new coordinate.
- [ ] Place new artists outward from the origin using collision-tested deterministic candidate positions. Add albums by an existing artist near its existing figure without moving earlier stars.
- [ ] Give Uncharted album-hash positions independent of arrival order. It has no figure lines, region glow, or alarm color.
- [ ] Form planets at album counts 20, 40, 60, and so on. Store ordered member IDs/timestamps, frontier radius, formation timestamp, seed, and descriptor. Deleting or retagging an album never changes membership.
- [ ] Backfill existing libraries in import order and write all missing planets in one transaction. Re-running backfill is a no-op.
- [ ] Derive band colors from quantized artwork samples; rotation from average known tempo; turbulence from known dynamic range; rings from genre purity; missing inputs use seed-derived defaults. Listening stats change vibrancy only, not surface identity.
- [ ] Generate the base 512×512 RGBA planet texture with fixed-width integer math and a versioned algorithm. Commit expected SHA-256 hashes for at least twelve fixtures so the same seed produces byte-identical pixels.
- [ ] Test that the 10,000-album fixture has 500 planets, no duplicate membership, bounded placement time, and no overlap with its saved frontier exclusion zones.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/SkyComposerTests \
  -only-testing:AppTests/PlanetModelTests
```

**Commit:** `feat(sky): persist Aeon's celestial grammar`

---

### Task 15: Render the persistent sky with Metal

**Files**

- Create `ios/App/App/Sky/Metal/SkyRenderer.swift`
- Create `ios/App/App/Sky/Metal/SkyMetalView.swift`
- Create `ios/App/App/Sky/Metal/SkyShaders.metal`
- Create `ios/App/App/Features/Sky/SkyScreen.swift`
- Create `ios/App/App/Features/Sky/SkyAccessibilityOverlay.swift`
- Create `ios/App/App/Features/Sky/SkyHUD.swift`
- Create `ios/App/AppTests/SkyCameraTests.swift`
- Create `ios/App/AppTests/SkyHitTestingTests.swift`
- Create `ios/App/AppUITests/SkyInteractionTests.swift`

**Produces**

- Full-bleed Metal sky that stays alive under every panel.
- Pan, pinch, tiered zoom, selection, locate, traces, and stable rotation behavior.
- Accessible navigation independent of Metal pixels.

- [ ] Write pure camera tests for pan/pinch anchoring, clamped scales, content framing, safe-area-independent world coordinates, rotation preservation, locate flight, and Reduce Motion cross-fade.
- [ ] Write hit-test tests for stars, planets, overlapping candidates, minimum touch expansion, and transforms at every zoom tier.
- [ ] Batch stars, figure lines, glows, traces, and planet quads by render pipeline. Upload catalogue changes through diffed buffers; do not rebuild all GPU resources every frame.
- [ ] Render fixed planet textures from Task 14. Compute traces from the planet to current member-star coordinates when selected; never store trace endpoints.
- [ ] Keep region/artist labels in a contrast-compliant SwiftUI/CoreText overlay synchronized to camera transforms. Atmosphere may stay faint; readable text may not.
- [ ] Implement handoff zoom tiers and stable camera persistence. Sky coordinates never reflow for device size or orientation.
- [ ] Implement HUD census, tier/altitude strip, now-playing line, import progress, planet progress, and a non-blocking ceremony layer. Omit the optional airlock, grain/glitch, Drift, planet jump list, and extra ceremonies.
- [ ] Add an accessibility overlay exposing regions → constellations → stars, descriptive labels, selected state, activate actions, and a custom rotor. Metal marks themselves are not the accessibility elements.
- [ ] Add deterministic UI launch arguments for empty, small, 1,000-album, 10,000-album, playing, planet-selected, and Uncharted fixtures.
- [ ] Record performance with signposts. Release targets are 60 fps for 1,000 albums and at least 30 fps for 10,000 on the oldest supported physical test device, with no per-frame heap growth.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/SkyCameraTests \
  -only-testing:AppTests/SkyHitTestingTests \
  -only-testing:AppUITests/SkyInteractionTests
```

**Commit:** `feat(sky): render the native collection in Metal`

---

### Task 16: Build the Aeon design system and adaptive native chrome

**Files**

- Modify `scripts/build-nocturne-font.py`
- Create `ios/App/App/Resources/AeonNocturne-Regular.otf`
- Copy font license/provenance files into `ios/App/App/Resources`
- Modify `ios/App/App/Info.plist`
- Create `ios/App/App/DesignSystem/*.swift`
- Modify `ios/App/App/Features/Root/AeonRootView.swift`
- Create `ios/App/AppTests/DesignTokenTests.swift`
- Create `ios/App/AppUITests/AdaptiveChromeTests.swift`

**Produces**

- Reusable handoff §19 components.
- Silver chamber material, square geometry, Nocturne typography, and artwork-derived playing tint.
- iPhone dock and iPad sidebar over one persistent sky.

- [ ] Make the font build emit reproducible OTF and WOFF from the same source. Bundle the OTF, register it through `UIAppFonts`, and test the PostScript name. Ship GUST, LPPL, and provenance files in the app bundle.
- [ ] Remove Arthemys from native font fallbacks. Use capped Dynamic Type for display sizes; SF Pro for UI and SF Mono with tabular digits for metrics.
- [ ] Define all color, spacing, stroke, shadow, duration, and z-order values in `AeonTheme`; feature files cannot introduce one-off chrome constants.
- [ ] Build `AeonScreen`, `AeonGlass`, `AeonBreadcrumb`, `AeonButton`, `AeonToggle`, `AeonSegment`, `AeonRow`, `AeonLabel`, `AeonArtwork`, `AeonSheet`, `AeonChrome`, `AeonEmptyState`, `AeonToast`, and `AeonProgressBar` before feature screens.
- [ ] Implement `AeonGlass` with a custom blur/tint/facet wrapper, black/bone/silver palette, hairline edge, zero corner radius, and opaque Reduce Transparency mode. Do not use SwiftUI `.material`.
- [ ] Sample one restrained tint from current artwork and expose it through environment state only while an album is loaded. Add a dark scrim beneath player/dock glass over bright artwork.
- [ ] Make one root safe-area coordinator own readable insets. The Metal sky ignores them; scroll content receives computed player plus dock/sidebar clearance and never sets independent magic padding.
- [ ] Implement compact bottom navigation for Sky, Library, Playlists, Settings. Implement regular-width sidebar that persists in landscape and overlays in iPad portrait. The sky remains mounted while destinations change.
- [ ] Add iPhone portrait/landscape and iPad portrait/landscape UI tests at normal and largest accessibility text sizes. Assert reachable last rows, no Dynamic Island/status-bar collision, no clipped primary actions, and 44×44 minimum targets.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/DesignTokenTests \
  -only-testing:AppUITests/AdaptiveChromeTests
```

**Commit:** `feat(ui): add Aeon's native visual system`

---

### Task 17: Build Library, search, album detail, and metadata editing

**Files**

- Create `ios/App/App/Features/Library/LibraryController.swift`
- Create `ios/App/App/Features/Library/LibraryScreen.swift`
- Create `ios/App/App/Features/Library/AlbumDetailView.swift`
- Create `ios/App/App/Features/Library/AlbumEditorView.swift`
- Create `ios/App/App/Features/Library/SearchResultsView.swift`
- Create `ios/App/AppTests/LibraryControllerTests.swift`
- Create `ios/App/AppUITests/LibraryFlowTests.swift`

**Produces**

- Native grid/list library, Continue Listening, sorting, search, album detail, editing, and Find in Sky.
- Compact sheets on iPhone and simultaneous sky/album side panel on iPad.

- [ ] Test sorting for Recent, Artist, Title, Year, and Played with missing values last and stable tie breaks. Search must match albums, artists, and tracks through indexed normalized fields and return track matches in their own section.
- [ ] Query grid/list summaries separately from album tracks. Paginate large libraries and prefetch thumbnails without decoding full-size artwork.
- [ ] Build one header count line, import action, Continue Listening card, and one shared control bar for search/sort/density. Do not reproduce stacked web controls or a second circular play control.
- [ ] Implement two compact grid columns, three at 600pt, four on standard iPad widths, and five only when artwork remains at least the handoff's intended size. List rows use 62pt art and shared separators.
- [ ] Distinguish currently playing from paused-but-loaded with `PLAYING` and `IN THE PLAYER`; both retain the artwork tint.
- [ ] Build album detail with `PLAY`, `FIND IN SKY`, ordered track rows, overflow, `EDIT`, and Add to Playlist. Reorder and Merge stay omitted for 5.0 per the handoff's optional list.
- [ ] `FIND IN SKY` dismisses/adjusts presentation, selects the exact persisted star, and moves the camera without changing coordinates. On iPad the side panel remains visible beside the highlighted sky.
- [ ] Build title, artist, year, genre, lookup, find-art, and pick-art editing. Empty values are omitted or phrased as actions; never display null, `<unknown>`, or `0000`.
- [ ] Before an edit that changes region placement, compute the complete affected artist set and show `This will move N star(s)`. On confirmation, update metadata and coordinates in one transaction; on cancel, write nothing.
- [ ] Put Delete Album in overflow only. Delete catalogue/artwork/copied media transactionally, preserve adopted files, scrub playlist and queue references, and never delete a star before repository commit succeeds.
- [ ] Cover empty-first-run, empty-filtered, unavailable-file, offline, partial import, corrupt artwork, and repository error states with native inline treatments.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/LibraryControllerTests \
  -only-testing:AppUITests/LibraryFlowTests
```

**Commit:** `feat(library): build the native collection interface`

---

### Task 18: Build Now Playing, Queue, EQ, and Spectrum

**Files**

- Create `ios/App/App/Features/Player/PlayerBar.swift`
- Create `ios/App/App/Features/Player/NowPlayingView.swift`
- Create `ios/App/App/Features/Player/QueueView.swift`
- Create `ios/App/App/Features/Player/EQView.swift`
- Create `ios/App/App/Playback/SpectrumAnalyzer.swift`
- Create `ios/App/AppTests/QueueControllerTests.swift`
- Create `ios/App/AppTests/SpectrumAnalyzerTests.swift`
- Create `ios/App/AppUITests/PlaybackFlowTests.swift`

**Produces**

- Persistent mini player, full player/detail pane, editable upcoming queue, audible EQ, reactive spectrum, and Locate.

- [ ] Bind every control to `PlaybackController`; views never infer state from timers or local booleans. Seek previews locally but commit one coordinator seek on release.
- [ ] Build the mini player with artwork, title, artist, play, next, and a 2pt progress edge. The non-control area expands Now Playing. Allow word-aware two-line fallback before truncation.
- [ ] Build Now Playing in the specified order: position, heading, artwork stage, title/artist/status, seek, transport, shuffle/repeat/queue, volume, secondary actions, EQ, Spectrum. The only circle is the primary transport glyph.
- [ ] Make `LOCATE` available from Now Playing and route it through the same camera command as Album Detail. It must take at most two taps from any destination.
- [ ] Implement queue drag reordering with an explicit 44pt handle. Pin the current row; mutate upcoming rows only; show the 1pt drop outline and 0.6 moving opacity; send one queue revision per completed move.
- [ ] Implement Clear Upcoming and Save as Playlist with inline naming. Reject empty names and preserve queue state if catalogue persistence fails.
- [ ] Keep the existing ten EQ bands and preset names `BASS RITUAL`, `VOCAL CULT`, `AIRWAVE`, `TUNNEL`. Active selection adds contrast. Bypass and preset changes cannot reload, seek, or revise the queue.
- [ ] Install an audio-engine tap for a bounded mono analysis buffer. Use Accelerate/vDSP for windowing and FFT, publish perceptual bands at no more than 30 Hz, allocate no buffers in the audio render callback, and uninstall cleanly.
- [ ] Stop spectrum reactivity under Reduce Motion and freeze/clear it when paused according to the final visual state. Spectrum data never becomes playback authority.
- [ ] Show source and actual output descriptors in the secondary detail area without claiming unavailable codec information. Show one restrained inline failure line for recoverable playback errors.
- [ ] Test background/foreground, lock-screen command updates, queue mutation during prepared-next playback, loaded-paused tint, missing current file, and rotation while Now Playing is open.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/QueueControllerTests \
  -only-testing:AppTests/SpectrumAnalyzerTests \
  -only-testing:AppTests/ReplayGainAndEQTests \
  -only-testing:AppUITests/PlaybackFlowTests
```

**Commit:** `feat(player): complete native playback surfaces`

---

### Task 19: Build Playlists, Settings, storage tools, and compatible backup/restore

**Files**

- Create `ios/App/App/Features/Playlists/PlaylistsController.swift`
- Create `ios/App/App/Features/Playlists/PlaylistsScreen.swift`
- Create `ios/App/App/Features/Settings/SettingsController.swift`
- Create `ios/App/App/Features/Settings/SettingsScreen.swift`
- Create `ios/App/App/Import/ArchiveReader.swift`
- Create `ios/App/App/Import/ArchiveWriter.swift`
- Create `ios/App/AppTests/PlaylistTests.swift`
- Create `ios/App/AppTests/ArchiveCompatibilityTests.swift`
- Create `ios/App/AppUITests/SettingsFlowTests.swift`

**Produces**

- Playlist creation/detail/playback and queue-save flow.
- Playback, Library, Sky, and footer settings hierarchy.
- Streaming full backup and catalogue-only export; transactional restore of legacy v1/v2 and native v3 archives.

- [ ] Test playlist creation, stable item ordering, missing-track display, delete, queue conversion, and referential cleanup after album deletion.
- [ ] Put creation behind the header `+`; keep inline create only in the `No routes charted yet.` empty state. Use a bundled celestial route mark rather than an emoji or generic music-note symbol.
- [ ] Build Settings sections exactly as Playback, Library, The Sky, then a plain footer. EQ/Spectrum rows deep-link to Now Playing; they are not duplicated controls.
- [ ] Preserve current metadata lookup, storage, backup, and `the sky goes dark` copy. Exclude the sample-data generator and all developer buttons from release builds.
- [ ] Implement filled-on/bare-off `AeonToggle`, explicit storage measurement, resumable artwork repair, HUD/contrast/motion settings, sleep timer, diagnostics export, and activity-log export.
- [ ] Implement catalogue-only JSON export first. Include schema version, stable IDs, metadata, playlists, listening stats, settings, queue checkpoint, sky seed, star coordinates, and planet records; omit audio and artwork bytes.
- [ ] Implement a streaming ZIP64 store-mode writer for full backups with data descriptors and CRC32. Never stage a second whole-library copy or hold a complete archive in RAM. Include `isolation-backup.json` compatibility metadata plus native v3 fields.
- [ ] Implement a bounded central-directory reader for store and deflate methods, ZIP32 and ZIP64, path traversal rejection, duplicate-path rejection, size/count limits, CRC verification, and extraction through `.incoming` files.
- [ ] Restore 4.x v1/v2 fixtures produced by the existing JS writer. Restore v3 into staging catalogue/files, validate every relationship and checksum, then publish in one transaction. Merge by stable ID, keep the higher play count, and never erase the existing library before validation succeeds.
- [ ] Route full export/import through native document pickers. Cancellation leaves the catalogue unchanged and removes only operation-owned partial files.
- [ ] Implement Erase Everything with the locked copy and typed `ERASE`. Quarantine the database/artwork/copied-media set first, create a fresh catalogue, then delete the quarantine only after successful relaunch; preserve adopted files and legacy IndexedDB.

**Gate**

```bash
npm run test:ios -- -only-testing:AppTests/PlaylistTests \
  -only-testing:AppTests/ArchiveCompatibilityTests \
  -only-testing:AppUITests/SettingsFlowTests
npm test
```

**Commit:** `feat(app): add native playlists settings and archives`

---

### Task 20: Accessibility, regression parity, release proof, and 5.0 packaging

**Files**

- Create/modify `ios/App/AppUITests/AeonAccessibilityTests.swift`
- Create `ios/App/AppUITests/AeonScreenMatrixTests.swift`
- Create `ios/App/AppTests/AudioIntegrationTests.swift`
- Modify `.github/workflows/ios-ipa.yml`
- Modify `package.json`
- Create `docs/validation/5.0-swiftui-screen-matrix.md`
- Create `docs/validation/5.0-migration-matrix.md`
- Create `docs/validation/5.0-audio-device-matrix.md`
- Create `docs/releases/5.0.md`

**Produces**

- Audited SwiftUI parity with the handoff and existing behavior.
- Automated accessibility/layout/migration/audio evidence.
- Physical-device evidence and a fresh unsigned Aeon 5.0 IPA.

- [ ] Run VoiceOver identifier/label/trait tests across every screen and state. Confirm sky rotor order, HUD announcements, visible focus, 44×44 targets, logical traversal, and no color-only status.
- [ ] Run normal, AX5, Increase Contrast, Reduce Transparency, Reduce Motion, light/dark system setting, iPhone portrait/landscape, and iPad portrait/landscape matrices. Aeon remains visually dark; system appearance must not invert it.
- [ ] Capture deterministic screenshots for empty, import, library grid/list, album detail, editor, playing/paused/error, queue drag, playlists empty/detail, settings, Uncharted, constellation, planet-selected, and iPad split layouts. Review them line-by-line against the Claude handoff.
- [ ] Re-run the original browser/Node suites against the untouched behavioral reference. Record deliberate native differences rather than weakening old assertions.
- [ ] Run native integration queues across 44.1 → 96 → 48 kHz, exact PCM gapless boundaries, compressed seek tolerance, queue replacement, restore-without-autoplay, corrupt/missing/unsupported media, and all recovery levels.
- [ ] Execute installed upgrades from the last 4.x native build with empty, path-backed, blob-backed, mixed, interrupted, missing-file, and 10,000-record fixture libraries. Compare manifests and confirm no source mutation.
- [ ] Execute the physical-device matrix on iPhone and iPad: speaker, wired/USB DAC, Bluetooth/AirPods, AirPlay, locked screen, background, incoming interruption, route removal, Control Center, hardware commands, mixed rates, import folder, migration, rotation, and sustained playback.
- [ ] Update CI so it installs dependencies, runs Node/browser oracle tests, runs all XCTest/XCUITest suites, copies/syncs migration assets, installs pods, and compiles a new Release `App.app` with signing disabled. Package that build only; never repackage an old payload.
- [ ] Keep Capacitor pods and `app/legacy-migration.*` in 5.0 solely for legacy reads. Assert in UI tests that the root controller and every visible screen are SwiftUI and that the normal `index.html` is never loaded.
- [ ] Fill `docs/releases/5.0.md` with exact test counts, device/OS/hardware, format matrix, source/output caveat, migration results, accessibility results, known limitations, and the deliberate omission list.

**Automated gate**

```bash
npm ci --no-audit --no-fund
npm test
npm run check
npm run test:browser
npm run test:interface
npm run test:arrival
npm run test:sky-chrome
npm run test:native-audio
node test/legacy-migration-contract.mjs
npm run test:ios
```

**Fresh package gate**

```bash
npx cap sync ios
cd ios/App
pod install
xcodebuild -workspace App.xcworkspace -scheme App \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
test -d build/Build/Products/Release-iphoneos/App.app
```

Physical-device rows remain `NOT RUN` until observed. They cannot be converted to pass from simulator or unit-test evidence.

**Commit:** `release: validate Aeon 5 native SwiftUI rebuild`

---

## Commit sequence and stop conditions

Execute Tasks 8 through 20 in order and keep one reviewable commit per task. Stop the cutover, preserve the last passing app, and repair before continuing if any of these occur:

- The upgrade build cannot read the existing `capacitor://localhost` IndexedDB.
- A migration test mutates or deletes its source.
- A path-backed track is copied unnecessarily or resolves outside Documents.
- Any catalogue operation can publish an album without at least one valid track reference.
- Star coordinates or planet membership change across a non-user-initiated rebuild.
- A SwiftUI control bypasses `PlaybackCoordinator` and mutates the graph directly.
- A screen becomes unreachable at an accessibility text size or under the shared player/dock inset.
- Memory grows with full library/archive size rather than bounded page/chunk size.
- CI packages an existing binary instead of the just-compiled product.

After each task, run its focused gate plus every previously created native suite. Before each push, run `git diff --check` and inspect the commit for generated build products, user libraries, media, credentials, or local signing data.

## Post-5.0 removal gate

Capacitor and the 4.x web assets are intentionally not removed in this release. A later release may remove them only after telemetry-free local checks show no `legacyBlob` records, migration has a successful completion marker, a native full backup has succeeded, and at least one shipped-version upgrade cycle has passed. The removal commit must preserve the Node fixtures and archived 4.x backup samples needed to test restore compatibility.
