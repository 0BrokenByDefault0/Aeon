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

test('one reusable shape and line token serve primary, segment, toggle, and icons', () => {
  assert.equal((components.match(/struct AeonSegmentedCapsule: Shape/g) || []).length, 1);
  assert.match(components, /static let stroke: CGFloat = 1\.125/);
  assert.match(components, /var chamberCount = 3/);
  assert.match(components, /var endWidth: CGFloat = 42/);
  assert.match(components, /path\.addEllipse\(in: oval\(index\)\)/);
  assert.match(components, /AeonGlyphPath\(kind: kind\)\.stroke\(style: AeonOrbit\.line\)/);
});

test('primary rest state is unfilled and press state fills only its center', () => {
  const style = components.split('struct AeonButtonStyle: ButtonStyle')[1].split('struct AeonToggleStyle')[0];
  assert.match(style, /tier == \.filled && configuration\.isPressed/);
  assert.match(style, /AeonSegmentedCapsule\(part: \.chamber\(1\)\)\.fill\(AeonOrbit\.activeFill\)/);
  assert.doesNotMatch(style, /AeonSegmentedCapsule\(\)\.fill/);
  assert.match(style, /AeonGlyph\(kind: \.star\)/);
  assert.match(style, /AeonGlyph\(kind: \.arrow\)/);
});

test('sleep choices form one fitted control with complete spoken labels', () => {
  assert.match(settings, /AeonSegment\([\s\S]*?values: SettingsSleepTimer\.allCases/);
  for (const label of ['OFF', '15', '30', '1H', 'END']) assert.ok(settings.includes(`return "${label}"`));
  assert.match(settings, /spokenLabel: \{ \$0\.label \}/);
  assert.doesNotMatch(settings, /ScrollView\(\.horizontal/);
  assert.match(components, /\.accessibilityAddTraits\(selection == value \? \.isSelected : \[\]\)/);
});

test('toggle keeps native accessibility semantics and a separate moving ellipse', () => {
  const style = components.split('struct AeonToggleStyle: ToggleStyle')[1].split('struct AeonSegment<Value')[0];
  assert.match(style, /\.accessibilityRepresentation/);
  assert.match(style, /Toggle\(isOn: configuration\.\$isOn\)/);
  assert.match(style, /part: \.knob,[\s\S]*?knobPosition: configuration\.isOn \? 1 : 0/);
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
  for (const id of ['aeon.library.import.files', 'aeon.library.import.folder', 'aeon.import.sheet']) assert.ok(components.includes(id));
  assert.match(components, /accessibilityElement\(children: \.contain\)\.accessibilityIdentifier\("aeon.import.sheet"\)/);
  assert.match(components, /Aeon only reads what you hand it\./);
  assert.doesNotMatch(components, /without pretending/);
});

test('empty states share a recipe with distinct motifs and a reachable action', () => {
  assert.match(sky, /motif: \.sky/);
  assert.match(components, /case \.sky: AeonGhostDisc\(\)/);
  assert.match(sky, /Your sky is quiet/);
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
  assert.match(sky, /paused: reduceMotion \|\| scenePhase != \.active/);
  assert.match(components, /paused: reduceMotion \|\| AeonTestOverrides\.reduceMotion \|\| scenePhase != \.active/);
  assert.doesNotMatch(components, /AeonBlur|RadialGradient/);
  assert.match(components, /\.clipShape\(Circle\(\)\)/);
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
  assert.match(style, /Button \{ configuration\.isOn\.toggle\(\) \} label: \{\s*HStack/);
  assert.match(style, /if showsLabel \{\s*configuration\.label\s*Spacer/);
  assert.match(style, /\.contentShape\(Rectangle\(\)\)/);
  assert.match(native, /toggle\.tap\(\)[\s\S]*?value != %@/);
  assert.match(native, /assertState\(toggle, predicate: "value ==/);
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
  assert.doesNotMatch(stage, /Rectangle\(/);
  assert.match(stage, /Circle\(\)/);
  assert.match(player, /playback\.seek\(to: \$0\)/);
  assert.match(native, /orbital-eq-presets-closeup/);
});
