# Aeon development workflow

## Repository map

| Area | Production source | First tests to inspect | Stable UI identifiers / entry points |
|---|---|---|---|
| Import | `ios/App/App/Import/`, `app/legacy-migration.*` | `LibraryImporterTests`, `AudioTagReaderTests`, `ImportPickerTests`, `ImportPickerPresentationTests` | `aeon.import.sheet`, `ImportPicker` |
| Playback / player | `ios/App/App/Audio/`, `ios/App/App/Playback/`, `ios/App/App/Features/Player/` | `PlaybackCoordinatorTests`, `PlaybackControllerTests`, `PlaybackFlowTests`, `PlayerNavigationTests` | `PlaybackController`, `NowPlayingView`, `PlayerBar` |
| Library | `ios/App/App/Features/Library/`, `ios/App/App/Persistence/`, `ios/App/App/Domain/` | `LibraryControllerTests`, `CatalogRepositoryTests`, `LibraryFlowTests` | `LibraryScreen`, `LibraryController` |
| Sky / Metal | `ios/App/App/Features/Sky/`, `ios/App/App/Sky/` | `SkyComposerTests`, `SkyCameraTests`, `SkyHitTestingTests`, `SkyInteractionTests` | `SkyScreen`, `SkySceneController`, `SkyRenderer` |
| Chrome / design system | `ios/App/App/DesignSystem/`, `ios/App/App/Features/Root/` | `DesignTokenTests`, `AdaptiveChromeTests`, `AeonAccessibilityTests` | `aeon.navigation.*`, `AeonChrome`, `AeonTheme` |
| Playlists | `ios/App/App/Features/Playlists/`, `ios/App/App/Persistence/` | `PlaylistTests`, `LibraryFlowTests`, `SettingsFlowTests` | `PlaylistsScreen`, `PlaylistsController` |
| Settings | `ios/App/App/Features/Settings/` | `SettingsFlowTests`, `DesignTokenTests` | `SettingsScreen`, `SettingsController` |
| Web compatibility / migration | `app/`, `test/`, `tests/` | matching Node or Playwright file, then `LegacyMigrationTests` | `LegacyMigrationViewController` |
| Build and delivery | `scripts/`, `.github/workflows/`, `ios/App/Podfile.lock` | `ios-test-runner.test.cjs`, `targeted-tests.test.cjs` | package scripts and workflow summaries |

The native app root is `AeonApp -> AppContainer -> AeonRootView`. The normal 5.0 UI is SwiftUI. The `app/` web surface remains a compatibility and migration oracle; do not treat it as the native UI implementation.

## Fast feature and fix loop

1. Search for the exact symbol, error, accessibility identifier, or failing test. Fetch the smallest useful line range.
2. Make the minimal implementation. Avoid cross-area cleanup.
3. Run `npm run test:targeted -- --area=<area>`. This runs syntax plus cheap Node or focused browser contracts relevant to that area.
4. On macOS, run `npm run test:targeted:native -- --area=<area>`. The default is one iPhone simulator and explicit XCTest/XCUITest selectors. Add `--family=ipad` only when the change is layout- or iPad-specific.
5. Push the coherent commit. `Build fast unsigned IPA` repeats changed-area routing, reuses the native build products, and publishes a validation manifest beside the IPA.

Use multiple areas when a change crosses boundaries:

```sh
npm run test:targeted -- --area=import --area=library
npm run test:targeted:native -- --area=import --area=library
```

For automatic routing from a Git base:

```sh
npm run test:targeted -- --changed-from=origin/main
```

Shared infrastructure or unrecognized production paths deliberately route to every area. Documentation-only changes route to configuration checks without consuming a simulator.

## Validation labels

Every fast IPA contains `Aeon-validation.txt` and the workflow publishes the same text in its summary. It records the commit, selected areas, cheap-check result, focused native result, simulator family, and explicitly states that deep regression and physical-device acceptance were not run. A fast IPA is never release evidence.

## Deep and release path

Run the manual `Deep release validation` workflow for a release candidate. It executes the complete Node/browser regression set and every native unit/UI shard on both iPhone and iPad simulators. Its artifacts contain bounded summaries and `.xcresult` bundles. Superseded runs cancel automatically.

Before release approval, attach physical-device evidence for:

- clean install and an in-place 4.x upgrade without catalogue or media loss;
- import from local, Files, remembered folder, and iCloud-placeholder cases;
- playback, backgrounding, lock-screen controls, interruptions, route changes, Bluetooth/AirPlay, and a wired/USB route where available;
- iPhone and iPad navigation, rotation, large text, VoiceOver, Reduce Motion, and Increase Contrast;
- Sky frame rate and memory targets on the oldest supported device.

Simulator or unsigned-IPA success cannot close these rows.

## Context and CI discipline

- Reuse the map above. Search first; fetch exact line ranges; compare diffs after edits.
- Keep the current failure summary and discard repetitive build output. CI uploads full bounded artifacts when detail is needed.
- Do not reread files that did not change. Do not load historical plans or unrelated features to solve a local failure.
- Keep commits independently understandable: agent guidance, test routing, and CI delivery should remain separable.
