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

test('all utility and player panels have opaque backing inside their width constraint', () => {
  assert.equal((root.match(/\.modifier\(AeonOpaquePanel\(\)\)/g) || []).length, 5);
  assert.match(root, /struct AeonOpaquePanel: ViewModifier[\s\S]*\.background\(AeonTheme\.ColorToken\.void\)/);
  const surface = root.split('struct AeonOpaquePanel: ViewModifier')[1];
  assert.doesNotMatch(surface, /\.opacity\(/);
  assert.equal((root.match(/\.frame\(width: width\)\s*\.modifier\(AeonOpaquePanel\(\)\)/g) || []).length, 5);
});

test('Sky stays mounted but inactive copy, actions and accessibility overlays do not', () => {
  assert.match(root, /isForeground: destination == \.sky && !nowPlayingVisible/);
  assert.match(sky, /if isForeground \{\s*SkyLabelOverlay/);
  const foreground = sky.split('if isForeground {')[1].split('.transaction')[0];
  for (const name of ['SkyAccessibilityOverlay', 'SkyHUD', 'emptyState', 'selectionLabel']) assert.ok(foreground.includes(name), name);
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
  assert.match(sky, /static let labels = \["UNCHARTED", "UNLIT"\]/);
  assert.match(sky, /ForEach\(Array\(AeonQuietSkyMarkers\.labels\.enumerated\(\)\)/);
  assert.doesNotMatch(sky, /"UNCHARTED", "UNLIT", "UNCHARTED"/);
  // Bearings are decorative and shown only while nothing is charted. The starfield
  // itself is the renderer's fixed-seed backdrop, not a second SwiftUI canvas.
  assert.match(sky, /struct AeonQuietSkyBearings: View/);
  assert.match(sky, /if controller\.catalogue\.stars\.isEmpty \{\s*AeonQuietSkyBearings\(\)/);
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
