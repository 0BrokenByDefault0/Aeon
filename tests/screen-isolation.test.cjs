// Source contracts. Pixel and navigation regressions run separately in native XCTest.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const base = process.env.AEON_SOURCE_ROOT || join(__dirname, '..');
const read = p => readFileSync(join(base, p), 'utf8');
const root = read('ios/App/App/Features/Root/AeonRootView.swift');
const sky = read('ios/App/App/Features/Sky/SkyScreen.swift');
const chrome = read('ios/App/App/DesignSystem/AeonChrome.swift');
const ui = read('ios/App/AppUITests/AdaptiveChromeTests.swift');
const tokens = read('ios/App/AppTests/DesignTokenTests.swift');

test('utility panels and full-screen player retain opaque isolated backing', () => {
  assert.equal((root.match(/\.modifier\(AeonOpaquePanel\(\)\)/g) || []).length, 4);
  assert.match(root, /struct AeonOpaquePanel: ViewModifier[\s\S]*\.background\(AeonTheme\.ColorToken\.void\)/);
  const player = root.split('private func nowPlayingPanel')[1].split('@ViewBuilder')[0];
  assert.match(player, /\.frame\(width: geometry\.size\.width, height: geometry\.size\.height\)/);
  assert.match(player, /\.background\(AeonTheme\.ColorToken\.void\.ignoresSafeArea\(\)\)/);
  assert.doesNotMatch(player, /padding\(\.bottom, insets\.bottom\)/);
  assert.match(root, /if !nowPlayingVisible \{\s*AeonChrome/);
  assert.match(root, /destinationPanel[^\n]*\n\s*\.accessibilityHidden\(nowPlayingVisible\)/);
  const surface = root.split('struct AeonOpaquePanel: ViewModifier')[1];
  assert.doesNotMatch(surface, /\.opacity\(/);
  assert.equal((root.match(/\.frame\(width: width\)(?:\s*\.clipped\(\))?\s*\.modifier\(AeonOpaquePanel\(\)\)/g) || []).length, 4);
});

test('Sky stays mounted but inactive copy, actions and accessibility overlays do not', () => {
  assert.match(root, /isForeground: destination == \.sky && !nowPlayingVisible/);
  assert.match(sky, /if isForeground \{\s*SkyLabelOverlay/);
  const foreground = sky.split('if isForeground {')[1].split('.transaction')[0];
  for (const name of ['SkyAccessibilityOverlay', 'SkyHUD', 'emptyState', 'selectionFocus']) assert.ok(foreground.includes(name), name);
  assert.match(sky, /SkyMetalView[\s\S]*\.allowsHitTesting\(isForeground\)/);
  assert.match(sky, /effectiveReduceMotion \|\| !isForeground/);
});

test('utility navigation does not crossfade two screens on top of each other', () => {
  assert.match(root, /\.zIndex\(AeonTheme\.Layer\.content\)[\s\S]*?\.transition\(\.identity\)/);
  assert.doesNotMatch(root, /\.animation\([^\n]*value: destination\)/);
  assert.match(sky, /\.transaction \{ \$0\.animation = nil \}/);
});

test('every compact indicator shares the same tab-local centered path', () => {
  assert.match(chrome, /if compact \{\s*AeonTabSelectionRule\(\)/);
  const rule = chrome.split('struct AeonTabSelectionRule: Shape')[1];
  assert.ok(rule);
  assert.match(rule, /rect\.midX - width \/ 2/);
  assert.match(rule, /rect\.midX \+ width \/ 2/);
  assert.match(rule, /let width = min\(24, max\(0, rect\.width\)\)/);
  assert.doesNotMatch(rule, /UIScreen|geometry\.size/);
  assert.match(chrome, /ignoresSafeArea\(\.container, edges: \.bottom\)/);
});

test('empty sky has exactly two distinct labels rather than repeated quadrant markers', () => {
  assert.doesNotMatch(sky, /"UNCHARTED"|"UNLIT"/);
  assert.match(sky, /Text\("Your sky is empty"\)/);
  // Bearings are decorative and shown only while nothing is charted. The starfield
  // itself is the renderer's fixed-seed backdrop, not a second SwiftUI canvas.
  assert.doesNotMatch(sky, /AeonQuietSkyBearings/);
  assert.match(sky, /if controller\.catalogue\.stars\.isEmpty \{\s*VStack/);
  assert.match(sky, /allowsHitTesting\(false\)\.accessibilityHidden\(true\)/);
  assert.doesNotMatch(sky, /Canvas \{ context, size in/);
});

test('native checks cover pixels, inactive actions, AX5 and returning to Sky', () => {
  assert.match(tokens, /XCTAssertEqual\(black, white/);
  assert.match(tokens, /ImageRenderer\(content:/);
  assert.match(tokens, /XCTAssertEqual\(bounds\.midX, rect\.midX/);
  assert.match(ui, /assertState\(app\.descendants\(matching: \.any\)\["aeon.sky.empty"\], predicate: "exists == false"\)/);
  assert.match(ui, /assertNoInactiveSky\(in: app, importButtons: 1\)/);
  assert.equal((ui.match(/assertNoInactiveSky\(in: app, importButtons: 0\)/g) || []).length, 3);
  assert.match(ui, /orbital-sky-return-after-tabs/);
});

test('paused and failed imports still chart their committed albums off the main thread', () => {
  const container = read('ios/App/App/AppContainer.swift');
  const exit = container.split('if !charted {')[1].split('self?.libraryImportToken = nil')[0];
  assert.match(exit, /Task\.detached\(priority: \.utility\) \{ _ = try\? sky\.backfill\(\) \}\.value/);
  assert.match(exit, /skySceneController\.reload\(\)/);
  assert.match(container, /skySceneController\.reload\(\)\s*\n\s*charted = true/);
});

test('a migration failure after publication opens the library instead of recovery', () => {
  const container = read('ios/App/App/AppContainer.swift');
  const migration = container.split('coordinator.onProgress =')[1].split('migrationCoordinator = coordinator')[0];
  const published = migration.split('if progress.phase == .failed, progress.catalogueReady {')[1].split('} else if progress.phase == .failed {')[0];
  assert.match(published, /self\.launchState = \.ready/);
  assert.match(published, /self\.legacyBridgeRequired = false/);
  assert.match(published, /self\.libraryImportError = "Some 4\.x audio could not be moved into Aeon\./);
  assert.doesNotMatch(published, /\.recovery\(/);
  const unpublished = migration.split('} else if progress.phase == .failed {')[1].split('} else {')[0];
  assert.match(unpublished, /\.recovery\(AppRecoveryState\(code: "legacy_migration_failed"/);
});

test('migration charts the Sky at publication and completion only', () => {
  const container = read('ios/App/App/AppContainer.swift');
  const migration = container.split('coordinator.onProgress =')[1].split('migrationCoordinator = coordinator')[0];
  assert.match(migration, /progress\.catalogueReady, !skyCharted \|\| progress\.sourceComplete/);
  assert.match(migration, /skyRepository\.backfill\(\)\s*\n\s*services\.skySceneController\.reload\(\)/);
});
