# Aeon development workflow

## Repository map

| Area | Production source | First tests to inspect | Stable UI identifiers / entry points |
|---|---|---|---|
| Import | `ios/App/App/Import/`, `app/legacy-migration.*` | `LibraryImporterTests`, `AudioTagReaderTests`, `ImportPickerTests`, `ImportPickerPresentationTests` | `aeon.import.sheet`, `ImportPicker` |

For large libraries, the supported native path is **Adopt Library** from the app-owned Files directory `On My iPhone/ISOLATION/Music`. Files placed there stay in place and are referenced through `MediaStore`; the external security-scoped folder picker is not part of release acceptance.
| Playback / player | `ios/App/App/Audio/`, `ios/App/App/Playback/`, `ios/App/App/Features/Player/` | `PlaybackCoordinatorTests`, `PlaybackControllerTests`, `PlaybackFlowTests`, `PlayerNavigationTests` | `PlaybackController`, `NowPlayingView`, `PlayerBar` |
| Library | `ios/App/App/Features/Library/`, `ios/App/App/Persistence/`, `ios/App/App/Domain/` | `LibraryControllerTests`, `CatalogRepositoryTests`, `LibraryFlowTests` | `LibraryScreen`, `LibraryController` |
| Sky / Metal | `ios/App/App/Features/Sky/`, `ios/App/App/Sky/` | `SkyComposerTests`, `SkyCameraTests`, `SkyHitTestingTests`, `SkyInteractionTests` | `SkyScreen`, `SkySceneController`, `SkyRenderer` |
| Chrome / design system | `ios/App/App/DesignSystem/`, `ios/App/App/Features/Root/` | `DesignTokenTests`, `AdaptiveChromeTests`, `AeonAccessibilityTests` | `aeon.navigation.*`, `AeonChrome`, `AeonTheme` |
| Playlists | `ios/App/App/Features/Playlists/`, `ios/App/App/Persistence/` | `PlaylistTests`, `LibraryFlowTests`, `SettingsFlowTests` | `PlaylistsScreen`, `PlaylistsController` |
| Settings | `ios/App/App/Features/Settings/` | `SettingsFlowTests`, `DesignTokenTests` | `SettingsScreen`, `SettingsController` |
| Web compatibility / migration | `app/`, `test/`, `tests/` | matching Node or Playwright file, then `LegacyMigrationTests` | `LegacyMigrationViewController` |
| Build and delivery | `scripts/`, `.github/workflows/`, `ios/App/Podfile.lock` | `ios-test-runner.test.cjs`, `targeted-tests.test.cjs`, `ipa-delivery-workflow.test.cjs` | package scripts and workflow summaries |

The native app root is `AeonApp -> AppContainer -> AeonRootView`. The normal 5.0 UI is SwiftUI. The `app/` web surface remains a compatibility and migration oracle; do not treat it as the native UI implementation.

## Fast feature and fix loop

1. Search for the exact symbol, error, accessibility identifier, or failing test. Fetch the smallest useful line range.
2. Make the minimal implementation. Avoid cross-area cleanup.
3. Run `npm run test:targeted -- --area=<area>`. This runs syntax plus cheap Node or focused browser contracts relevant to that area.
4. Push the coherent commit. `Build fast unsigned IPA` repeats cheap changed-area checks, builds the device app, and packages and uploads the unsigned IPA with its validation manifest before any native tests execute. Deliver the artifact as soon as it is available; do not wait for the workflow to finish.
5. After IPA upload, the fast workflow runs all `AppTests` unit tests on one iPhone simulator, under one 600-second deadline. UI validation is explicitly marked NOT RUN in the fast report. On macOS, the equivalent is `npm run test:targeted:native -- --area=<area>`, also after IPA delivery. The default is one iPhone simulator and explicit XCTest/XCUITest selectors. Add `--family=ipad` only when the change is layout- or iPad-specific. Native failures keep CI red and produce failure evidence, but do not remove or block the uploaded IPA.

Use multiple areas when a change crosses boundaries:

```sh
npm run test:targeted -- --area=import --area=library
# Push, build, upload, and deliver the fast IPA before the next command.
npm run test:targeted:native -- --area=import --area=library
```

For automatic routing from a Git base:

```sh
npm run test:targeted -- --changed-from=origin/main
```

Shared infrastructure or unrecognized production paths deliberately route to every area. Documentation-only changes route to configuration checks without consuming a simulator.

## Validation labels

Every fast IPA contains `Aeon-validation.txt` and the workflow publishes the same text in its summary. It records the commit, build-run URL, selected areas, and passed cheap checks. At upload time, focused native validation is `PENDING` on one iPhone simulator, `SKIPPED by manual request`, or `NOT REQUIRED for configuration-only change`; it must never claim native tests passed before they ran. Deep regression and physical-device acceptance remain explicitly `NOT RUN`. A fast IPA is never release evidence.

The workflow publishes the IPA download link before native execution. Afterwards, `Aeon-native-validation.txt` and the separate `Aeon-fast-native-validation-<run-id>` artifact report the native outcome for the same commit without modifying the already-delivered IPA. Failures also retain the focused failure artifact. If the runner is terminated before reporting, use the live run status; a pending manifest is not proof of a pass.

The manual `skip_native` input defaults to `false` and only skips post-upload testing. No emergency option is needed for IPA-first delivery. Artifact alerts must check for an IPA even while its workflow is running or has later failed, verify its commit, and report test status separately.

## Deep and release path

Run the manual `Deep release validation` workflow for a release candidate. It executes the complete Node/browser regression set, builds simulator products once, then runs unit tests and each individual UI case on both iPhone and iPad simulators. Each native compilation or test stage has a 600-second watchdog. UI cases reuse the compiled products; the matrix cancels remaining cases on a failure or timeout and never retries automatically. Its artifacts contain bounded summaries and `.xcresult` bundles. Superseded runs cancel automatically.

Before release approval, attach physical-device evidence for:

- clean install and an in-place 4.x upgrade without catalogue or media loss;
- import copied files, adopt/rescan Files → On My iPhone → ISOLATION → Music in place, and iCloud-placeholder cases;
- playback, backgrounding, lock-screen controls, interruptions, route changes, Bluetooth/AirPlay, and a wired/USB route where available;
- iPhone and iPad navigation, rotation, large text, VoiceOver, Reduce Motion, and Increase Contrast;
- Sky frame rate and memory targets on the oldest supported device.

Simulator or unsigned-IPA success cannot close these rows.

## Context and CI discipline

- Reuse the map above. Search first; fetch exact line ranges; compare diffs after edits.
- Keep the current failure summary and discard repetitive build output. CI uploads full bounded artifacts when detail is needed.
- Do not reread files that did not change. Do not load historical plans or unrelated features to solve a local failure.
- Keep commits independently understandable: agent guidance, test routing, and CI delivery should remain separable.

## Audit hardening — 2026-09-25

Native SwiftUI is the supported product surface. The bundled web app is retained for existing data migration and compatibility checks; it is not a second feature-development target. Its historical small-screen player overflow remains explicitly recorded by `test:interface:ci`; the raw interface test still fails on that assertion. No migration code or browser assertions have been removed.

Fast delivery validates all native unit tests (`--scope=unit`) after uploading the IPA. UI validation, deep regression, hardware audio routes, real Files-provider behavior, Metal export fidelity, VoiceOver navigation, and performance on physical devices remain separate acceptance work. A unit pass never closes those rows.

Storage changes protect the catalogue commit boundary, preserve an interrupted erase journal, enforce expanded-byte quotas before ZIP writes, and serialize operations that copy, remove, or inspect managed files. Restore now previews replacement counts. Library Health is read-only and never labels collector-owned adopted files as disposable. Missing successors are reported and skipped, with at most 32 decoder attempts per boundary.

Native listening counts accumulate actual playing time, qualifying at 30 seconds or half a shorter track. Pause and seeks do not create extra plays; repeat occurrences do. Broad Sky regions use a curated presentation taxonomy while original genre strings and established celestial coordinates stay intact. Sky exports share the live Metal pipelines.
