// Structural regressions. Geometry and real taps are additionally checked by native tests.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {createHash} = require('node:crypto');
const read = p => readFileSync(join(__dirname, '..', p), 'utf8');
const component = read('ios/App/App/DesignSystem/AeonComponents.swift');
const library = read('ios/App/App/Features/Library/LibraryScreen.swift');
const sky = read('ios/App/App/Features/Sky/SkyScreen.swift');
const playlists = read('ios/App/App/Features/Playlists/PlaylistsScreen.swift');
const settings = read('ios/App/App/Features/Settings/SettingsScreen.swift');
const native = read('ios/App/AppUITests/AdaptiveChromeTests.swift');
const unit = read('ios/App/AppTests/DesignTokenTests.swift');

test('the reticle survives every control box it is drawn into', () => {
  const mark = component.split('struct AeonReticleMark: Shape')[1].split('struct AeonReticleField')[0];
  // A box too small for four separated corners is grown about its own centre, and the
  // arms are capped at a third of each span. Without both, overlaying the mark on a
  // two-letter label collapsed it into a smear straight through the glyphs.
  assert.match(mark, /static let minimumSize = CGSize\(width: 44, height: 26\)/);
  assert.match(mark, /static func resolvedBox\(in bounds: CGRect\) -> CGRect/);
  assert.match(mark, /max\(bounds\.width, minimumSize\.width\)/);
  assert.match(mark, /min\(pressed \? 15 : 12, \(right - left\) \/ 3, \(bottom - top\) \/ 3\)/);
  assert.match(unit, /XCTAssertGreaterThanOrEqual\(resolved\.width, AeonReticleMark\.minimumSize\.width\)/);
  assert.match(unit, /testReticleKeepsFourSeparateCornersInEveryControlBox/);
});
test('timer visual geometry and rectangular hit cells agree', () => {
  const segment = component.split('struct AeonSegment<Value')[1].split('struct AeonRow')[0];
  assert.match(segment, /let cellWidth = geometry\.size\.width \/ CGFloat\(max\(1, values\.count\)\)/);
  assert.match(segment, /\.frame\(width: cellWidth, height: 48\)\s*\.contentShape\(Rectangle\(\)\)/);
  // The mark is one cell wide and centred on the chosen cell, and travels to it.
  assert.match(segment, /AeonReticleMark\(\)[\s\S]*?\.frame\(width: cellWidth, height: 48\)/);
  assert.match(segment, /offset\(x: -geometry\.size\.width \/ 2 \+ cellWidth \* \(CGFloat\(index\) \+ 0\.5\)\)/);
  assert.match(segment, /AeonFeedback\.selectionChanged\(\)/);
  assert.match(native, /for x in \[0\.15, 0\.85\]/);
  assert.match(native, /XCTAssertEqual\(options\.filter \{ \$0\.isSelected \}\.count, 1\)/);
});
test('toggle displays boolean words with native switch semantics and a full row target', () => {
  const toggle = component.split('struct AeonToggleStyle')[1].split('struct AeonSegment<Value')[0];
  assert.match(toggle, /Text\("OFF"\)/);
  assert.match(toggle, /Text\("ON"\)/);
  assert.doesNotMatch(toggle, /Text\("[−+]"\)/);
  assert.match(toggle, /frame\(width: 112, height: 44\)/);
  // Two equal 56pt cells, so the reticle always marks a full box rather than letterforms
  // and the control's trailing edge lines up with every other row value.
  assert.equal((toggle.match(/\.frame\(width: 56, height: 44\)/g) || []).length, 2);
  assert.match(toggle, /accessibilityRepresentation/);
  assert.match(toggle, /Button \{\s*AeonFeedback\.activated\(\)\s*configuration\.isOn\.toggle\(\)\s*\} label:/);
});
test('the three collection empty states share one recipe, preserving their separate metaphors', () => {
  for (const [screen, motif] of [[sky, 'sky'], [library, 'collection'], [playlists, 'route']]) {
    assert.match(screen, /AeonEmptyState\(/);
    assert.ok(screen.includes(`motif: .${motif}`));
  }
  assert.match(library, /actionTitle: "IMPORT MUSIC"/);
  assert.match(library, /if hasLibraryContent \{\s*Button/);
  assert.match(native, /emptyLibrary\.frame\.contains\(libraryImport\.frame\)/);
});
test('H1 screens omit duplicate destination eyebrows, retaining Library count', () => {
  assert.doesNotMatch(library, /AeonBreadcrumb\(text: "Library"\)/);
  assert.doesNotMatch(playlists, /AeonBreadcrumb\(text: "Playlists"\)/);
  assert.doesNotMatch(settings, /AeonBreadcrumb\(text: "Settings"\)/);
  assert.match(library, /accessibilityIdentifier\("aeon.library.count"\)/);
});
test('import rows have rounded outlines and top-aligned icon/title stacks', () => {
  const cards = component.split('private func importOption')[1].split('private struct AeonImportContentHeight')[0];
  assert.match(cards, /HStack\(alignment: \.top/);
  assert.match(cards, /RoundedRectangle\(cornerRadius: AeonTheme.Radius.control, style: \.continuous\)/);
  assert.match(cards, /AeonGlyph\(kind: \.picker\)/);
  assert.doesNotMatch(cards, /AeonGlyph\(kind: \.arrow\)|\.fill\(/);
  // Presentation timing is deliberately not changed in a visual pass.
  assert.match(cards, /dismiss\(\)\s*DispatchQueue.main.asyncAfter\(deadline: \.now\(\) \+ AeonTheme.Duration.chrome\) \{ action\(\) \}/);
});
test('sheet fits measured content without replacing its identity or handlers', () => {
  const sheet = component.split('struct AeonImportSheet')[1].split('struct AeonToast')[0];
  assert.match(sheet, /onPreferenceChange\(AeonImportContentHeight.self\)/);
  assert.match(sheet, /\.height\(contentHeight \+ AeonTheme.Space.medium \* 2 \+ AeonOrbit.stroke\)/);
  assert.match(sheet, /isAccessibilitySize/);
  assert.doesNotMatch(sheet, /\.id\(/);
  assert.match(sheet, /Import files, or scan the Music folder Aeon owns in Files\./);
});
test('disclosure, selection, creation and export no longer share the swash arrow', () => {
  assert.match(library, /AeonGlyph\(kind: \.disclosure\)/);
  assert.match(playlists, /AeonGlyph\(kind: \.add\)/);
  assert.match(settings, /glyph: AeonGlyphKind = \.disclosure/);
  assert.match(settings, /glyph: \.export/);
  assert.match(settings, /glyph: \.picker/);
  for (const screen of [library, playlists, settings]) assert.doesNotMatch(screen, /AeonGlyph\(kind: \.arrow\)/);
});
test('supporting copy uses regular weight and privacy disclosure survives', () => {
  assert.match(component, /supportingFont = AeonTheme.FontToken.ui\(\.subheadline, weight: \.regular\)/);
  assert.match(settings, /Only those words are sent, never your files\./);
  assert.doesNotMatch(settings, /ui\(\.callout, weight: \.medium\)/);
  assert.match(settings, /accessibilityIdentifier\("aeon.settings.build"\)/);
});
test('original navigation tests and foreground gating survive the polish', () => {
  const original = Buffer.from(native.split('\nextension AdaptiveChromeTests {')[0]);
  const sha = createHash('sha1').update(`blob ${original.length}\0`).update(original).digest('hex');
  assert.equal(sha, 'b607fe9a9c2c86180fab4eb6ab6b4a4dfa6e5bcd');
  assert.match(sky, /if isForeground/);
  assert.match(sky, /\.transaction \{ \$0.animation = nil \}/);
  assert.match(native, /assertNoInactiveSky\(in: app, importButtons: 0\)/);
});
