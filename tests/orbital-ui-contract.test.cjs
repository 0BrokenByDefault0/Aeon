// Cheap source contracts only. Native interaction and visual evidence live in AdaptiveChromeTests.
const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {createHash} = require('node:crypto');
const root = join(__dirname, '..');
const read = path => readFileSync(join(root, path), 'utf8');
const source = name => read(`ios/App/App/${name}.swift`);
const components = source('DesignSystem/AeonComponents');
const chrome = source('DesignSystem/AeonChrome');
const settings = source('Features/Settings/SettingsScreen');
const sky = source('Features/Sky/SkyScreen');
const library = source('Features/Library/LibraryScreen');
const playlists = source('Features/Playlists/PlaylistsScreen');
const native = read('ios/App/AppUITests/AdaptiveChromeTests.swift');
const workflow = read('.github/workflows/ios-ipa.yml');

test('reticle marks replace capsule controls', () => {
  assert.equal((components.match(/struct AeonReticleMark: Shape/g) || []).length, 1);
  assert.match(components, /static let stroke: CGFloat = 1/);
  assert.match(components, /lineCap: \.butt/);
  assert.doesNotMatch(components, /AeonSegmentedCapsule/);
  assert.match(components, /AeonGlyphPath\(kind: kind\)\.stroke\(style: AeonOrbit\.line\)/);
});

test('primary actions are unfilled at rest and wash only inside the ticks when pressed', () => {
  const style = components.split('struct AeonButtonStyle: ButtonStyle')[1].split('struct AeonToggleStyle')[0];
  assert.match(style, /AeonReticleMark\(pressed: configuration\.isPressed\)/);
  // Every fill in the style is gated on isPressed and scoped to the reticle field,
  // so nothing is ever a filled shape at rest.
  for (const fill of style.match(/^.*\.fill\(.*$/gm) || []) {
    assert.match(fill, /AeonReticleField\(\)\.fill\(AeonOrbit\.activeFill\)/, fill.trim());
  }
  assert.match(style, /if tier != \.bare, configuration\.isPressed \{\s*AeonReticleField\(\)\.fill/);
  // Primary actions keep the house marks by default; a transport action overrides them.
  assert.match(style, /var leadingMark: AeonGlyphKind = \.star/);
  assert.match(style, /var trailingMark: AeonGlyphKind = \.arrow/);
  assert.match(style, /AeonGlyph\(kind: leadingMark\)/);
  assert.match(style, /AeonGlyph\(kind: trailingMark\)/);
  // The visual press delta is small, so the haptic has to carry the confirmation.
  assert.match(style, /AeonFeedback\.activated\(\)/);
});

test('sleep choices form one fitted control with complete spoken labels', () => {
  assert.match(settings, /AeonSegment\([\s\S]*?values: SettingsSleepTimer\.allCases/);
  for (const label of ['OFF', '15M', '30M', '60M', 'END']) assert.ok(settings.includes(`return "${label}"`));
  assert.match(settings, /spokenLabel: \{ \$0\.label \}/);
  assert.doesNotMatch(settings, /ScrollView\(\.horizontal/);
  assert.match(components, /\.accessibilityAddTraits\(selection == value \? \.isSelected : \[\]\)/);
});

test('toggle keeps native accessibility semantics without a capsule', () => {
  const style = components.split('struct AeonToggleStyle: ToggleStyle')[1].split('struct AeonSegment<Value')[0];
  assert.match(style, /\.accessibilityRepresentation/);
  assert.match(style, /Toggle\(isOn: configuration\.\$isOn\)/);
  assert.match(style, /Text\("OFF"\)/);
  assert.match(style, /Text\("ON"\)/);
  assert.match(style, /AeonReticleMark\(\)/);
  assert.match(style, /frame\(width: 112, height: 44\)/);
  assert.match(style, /minHeight: AeonTheme\.Space\.minimumTarget/);
});

test('navigation has no selected fill and extends background rather than targets into safe area', () => {
  assert.doesNotMatch(chrome, /surfaceSelected|RoundedRectangle/);
  assert.match(chrome, /ignoresSafeArea\(\.container, edges: \.bottom\)/);
  assert.doesNotMatch(chrome, /padding\(\.bottom, bottomInset\)/);
  assert.match(chrome, /AeonGlyph\(kind: item\.glyph\)/);
  assert.match(chrome, /\.contentShape\(Rectangle\(\)\)/);
  assert.match(native, /window[s]?\.firstMatch\.frame\.contains\(button\.frame\)/);
});

test('first-pass surfaces retire stock capsules and preserve identifiers', () => {
  for (const text of [components, chrome, settings, sky, library, playlists]) assert.doesNotMatch(text, /\bCapsule\(/);
  for (const id of ['aeon.library.import.files', 'aeon.library.import.adopt', 'aeon.import.sheet']) assert.ok(components.includes(id));
  assert.match(components, /accessibilityElement\(children: \.contain\)\.accessibilityIdentifier\("aeon.import.sheet"\)/);
  assert.match(components, /Import files, or scan the Music folder Aeon owns in Files\./);
  assert.doesNotMatch(components, /without pretending/);
});

test('Sky empty state uses the shared recipe with its own motif', () => {
  assert.match(sky, /AeonEmptyState\(title: "Your sky is quiet"/);
  assert.match(sky, /motif: \.sky/);
  assert.match(components, /case \.sky: AeonGhostDisc\(\)/);
  assert.match(library, /motif: \.collection/);
  assert.match(components, /case \.collection: AeonCollectionMark\(\)/);
  assert.match(library, /Your collection starts here\./);
  assert.match(library, /actionTitle: "IMPORT MUSIC", motif: \.collection/);
  assert.match(library, /if hasLibraryContent \{\s*Button \{ importSheetPresented = true \}/);
  assert.match(playlists, /No routes charted yet\./);
  assert.match(components, /struct AeonRouteMark/);
  assert.match(playlists, /ScrollView \{/);
});

test('motion pauses and utility panels do not smear the live sky', () => {
  assert.match(sky, /effectiveReduceMotion/);
  assert.match(components, /paused: reduceMotion \|\| AeonTestOverrides\.reduceMotion \|\| scenePhase != \.active/);
  assert.doesNotMatch(components, /AeonBlur|RadialGradient/);
  assert.doesNotMatch(components, /\.clipShape\(Circle\(\)\)/);
});

test('library shelves use actual region membership and retain pagination', () => {
  assert.match(library, /catalogue\.stars\.map \{ \(\$0\.albumID, \$0\.regionID\) \}/);
  assert.match(library, /ForEach\(shelves\)/);
  assert.match(library, /controller\.loadNextPage\(\)/);
});

test('prior native navigation assertions remain byte-for-byte intact', () => {
  const original = native.split('\nextension AdaptiveChromeTests {')[0];
  const buffer = Buffer.from(original);
  const sha = createHash('sha1').update(`blob ${buffer.length}\0`).update(buffer).digest('hex');
  assert.equal(sha, 'b607fe9a9c2c86180fab4eb6ab6b4a4dfa6e5bcd');
  assert.match(native, /XCTAssertEqual\(count\.label, "1 ALBUM"/);
  assert.match(native, /XCTAttachment\(screenshot: element\.screenshot\(\)\)/);
});

test('UI evidence follows IPA delivery and does not prevent broader native checks', () => {
  const names = ['Publish IPA download link', 'Capture orbital UI review', 'Export orbital UI screenshots', 'Upload orbital UI screenshots', 'Run focused native validation'];
  const positions = names.map(name => workflow.indexOf(`- name: ${name}`));
  assert.ok(positions.every(p => p >= 0));
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b));
  assert.match(workflow, /id: native\n        if: \$\{\{ always\(\) && steps\.upload_ipa\.outcome == 'success'/);
  assert.match(workflow, /xcresulttool export attachments --path/);
  assert.match(workflow, /Commit: %s/);
  assert.doesNotMatch(workflow, /continue-on-error/);
});


test('switch row activation wraps the label, spacer, and traveling knob in one button', () => {
  const style = components.split('struct AeonToggleStyle: ToggleStyle')[1].split('struct AeonSegment<Value')[0];
  assert.match(style, /Button \{\s*AeonFeedback\.activated\(\)\s*configuration\.isOn\.toggle\(\)\s*\} label: \{\s*HStack/);
  assert.match(style, /if showsLabel \{\s*configuration\.label\s*Spacer/);
  assert.match(style, /\.contentShape\(Rectangle\(\)\)/);
  assert.match(native, /toggle\.tap\(\)[\s\S]*?waitForValueChange\(toggle, from: original/);
  assert.match(native, /changedToggle\.tap\(\)[\s\S]*?waitForValue\(changedToggle, equalTo: original/);
});

test('player controls reuse the orbital system without changing preset gains or actions', () => {
  const eq = source('Features/Player/EQView');
  const player = source('Features/Player/NowPlayingView');
  assert.doesNotMatch(eq, /\bCapsule\(|toggleStyle\(\.switch\)/);
  assert.doesNotMatch(player, /\bCapsule\(/);
  assert.match(eq, /AeonToggleStyle\(showsLabel: false\)/);
  assert.match(eq, /values: Self\.presets\.map\(\\\.name\)/);
  assert.match(eq, /Preset\(name: "BASS RITUAL", gains: \[9, 8, 6, 3, 0, -1, 0, 0, 1, 2\]\)/);
  assert.match(eq, /playback\.setEQ\(enabled: true, bands: bands\)/);
  const stage = player.split('private func artworkStage')[1].split('private func metadata')[0];
  assert.doesNotMatch(stage, /Circle\(\)/);
  assert.match(stage, /AeonReticleMark\(\)/);
  assert.match(player, /playback\.seek\(to: \$0\)/);
  assert.match(native, /orbital-eq-presets-closeup/);
});
