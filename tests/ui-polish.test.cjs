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
  assert.match(segment, /\.frame\(width: cellWidth, height: 48\)[\s\S]*?\.contentShape\(Rectangle\(\)\)/);
  assert.match(segment, /\.background\(selection == value \? AeonOrbit\.activeFill : \.clear\)/);
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
test('utility empty states share a recipe while Sky remains an immersive universe', () => {
  for (const [screen, motif] of [[library, 'collection'], [playlists, 'route']]) {
    assert.match(screen, /AeonEmptyState\(/);
    assert.ok(screen.includes(`motif: .${motif}`));
  }
  assert.doesNotMatch(sky, /AeonEmptyState\(/);
  assert.match(sky, /Text\("Your sky is empty"\)/);
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
  // The sheet also carries a mini player while something is loaded; its height is part
  // of the detent, or the last paragraph is cut off behind it.
  assert.match(sheet, /\.height\(contentHeight \+ AeonTheme.Space.medium \* 2 \+ AeonOrbit.stroke \+ playerBarHeight\)/);
  assert.match(sheet, /onPreferenceChange\(AeonModalPlayerBarHeight.self\)/);
  assert.match(read('ios/App/App/Features/Player/PlayerBar.swift'), /preference\(key: AeonModalPlayerBarHeight\.self, value: geometry\.size\.height\)/);
  assert.match(sheet, /isAccessibilitySize/);
  assert.doesNotMatch(sheet, /\.id\(/);
  assert.match(sheet, /Import files, or adopt everything in Files → ISOLATION → Music\./);
});
test('disclosure, selection, creation and export no longer share the swash arrow', () => {
  assert.match(library, /AeonGlyph\(kind: \.disclosure\)/);
  assert.match(playlists, /AeonGlyph\(kind: \.add\)/);
  assert.match(library, /Text\("IMPORT"\)[\s\S]{0,200}AeonGlyph\(kind: \.picker\)/);
  assert.doesNotMatch(library, /AeonGlyph\(kind: \.add\)/);
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

test('manual metadata lookups disclose what they send', () => {
  const editor = readFileSync(join(__dirname, '..', 'ios/App/App/Features/Library/AlbumEditorView.swift'), 'utf8');
  const settingsSource = readFileSync(join(__dirname, '..', 'ios/App/App/Features/Settings/SettingsScreen.swift'), 'utf8');
  assert.match(editor, /Find Art and Look Up Genre send this album’s title and artist to Apple and MusicBrainz\. Nothing else leaves the device\./);
  assert.match(editor, /aeon\.album\.editor\.lookup-disclosure/);
  assert.match(settingsSource, /Find Art and Look Up Genre in the album editor send the same words when you tap them\./);
});

test('the album editor opens as a page sheet so every field is visible on iPad', () => {
  const detail = read('ios/App/App/Features/Library/AlbumDetailView.swift');
  assert.match(detail, /\.sheet\(isPresented: \$editing\) \{\s*AlbumEditorView\([^\n]*\)[\s\S]{0,260}\.presentationSizing\(\.page\)/);
});

test('launch, migration and recovery actions use the shared orbital button style', () => {
  const root = read('ios/App/App/Features/Root/AeonRootView.swift');
  assert.doesNotMatch(root, /\.buttonStyle\(\.(borderedProminent|bordered)\)/);
  assert.match(root, /Button\("Retry"\) \{ container\.retryStartup\(\) \}\s*\n\s*\.buttonStyle\(AeonButtonStyle\(tier: \.filled\)\)/);
  assert.match(root, /Button\("Continue with Available Files"\)[^\n]*\n\s*\.buttonStyle\(AeonButtonStyle\(tier: \.filled\)\)/);
});

test('the first-run Sky import is the filled primary action and launch never flashes white', () => {
  const skySource = read('ios/App/App/Features/Sky/SkyScreen.swift');
  const empty = skySource.split('private var emptyState: some View {')[1].split('if let importError')[0];
  assert.match(empty, /Button\("IMPORT MUSIC"\) \{ importSheetPresented = true \}\s*\n\s*\.buttonStyle\(AeonButtonStyle\(tier: \.filled\)\)/);
  assert.doesNotMatch(empty, /\.buttonStyle\(\.plain\)/);
  assert.match(empty, /nocturnePostScriptName/);
  const launch = read('ios/App/App/Base.lproj/LaunchScreen.storyboard');
  assert.doesNotMatch(launch, /systemBackgroundColor/);
  assert.match(launch, /appearance="dark"/);
});

test('user-facing copy never exposes internal identifiers or file paths', () => {
  const hud = read('ios/App/App/Features/Sky/SkyHUD.swift');
  assert.doesNotMatch(hud, /tier\.rawValue/);
  assert.match(hud, /Sky altitude, \\\(tier\.spokenName\)/);
  const skySource = read('ios/App/App/Features/Sky/SkyScreen.swift');
  assert.doesNotMatch(skySource, /star\.title \?\? star\.albumID/);
  const settingsController = read('ios/App/App/Features/Settings/SettingsController.swift');
  assert.doesNotMatch(settingsController, /operationMessage = "[^"]*progress\.currentPath/);
  assert.doesNotMatch(playlists, /Text\("M3U"\)/);
});

test('equalizer and device-correction panels use Aeon tokens, tiers and the shared field', () => {
  for (const file of ['ios/App/App/Features/Player/ParametricControls.swift', 'ios/App/App/Features/Player/EQView.swift']) {
    const source = read(file);
    assert.doesNotMatch(source, /textFieldStyle\(\.roundedBorder\)/, file);
    assert.doesNotMatch(source, /foregroundStyle\(\.orange\)/, file);
    assert.doesNotMatch(source, /\.font\(\.(caption|headline)\)/, file);
  }
  assert.match(component, /struct AeonFieldStyle: TextFieldStyle/);
  assert.match(read('ios/App/App/Features/Player/ParametricControls.swift'), /DisclosureGroup\("Supported profile files"\)/);
});

test('launch, migration and recovery screens use type tokens and the app name', () => {
  const rootSource = read('ios/App/App/Features/Root/AeonRootView.swift');
  assert.doesNotMatch(rootSource, /\.font\(\.system\(/);
  // Inside the app the name is Aeon. ISOLATION is the home-screen name, and so the name
  // of the app's folder in Files; only copy that points at that folder may use it.
  assert.match(rootSource, /launchMessage\("OPENING AEON"\)/);
  assert.match(rootSource, /Text\("AEON COULD NOT OPEN"\)/);
  assert.doesNotMatch(rootSource, /ISOLATION/);
});

test('plain-label controls route touch feedback through AeonFeedback', () => {
  assert.match(component, /struct AeonPlainButtonStyle: ButtonStyle[\s\S]*?AeonFeedback\.activated\(\)/);
  for (const file of ['Features/Sky/SkyScreen.swift', 'Features/Sky/SkyHUD.swift', 'Features/Playlists/PlaylistsScreen.swift', 'Features/Settings/SettingsScreen.swift']) {
    assert.doesNotMatch(read(`ios/App/App/${file}`), /\.buttonStyle\(\.plain\)/, file);
  }
});

test('phone review fixes: rules, wrapping, placeholder years and storage figures', () => {
  const detail = read('ios/App/App/Features/Library/AlbumDetailView.swift');
  // Album facts are ruled across the whole column, like the track rows beneath them.
  assert.match(detail, /metadataValue\("TRACKS"[^\n]*\n\s*\}\n(\s*\/\/[^\n]*\n)*\s*\.frame\(maxWidth: \.infinity, alignment: \.leading\)\n\s*\.padding\(\.vertical, 14\)/);
  // A year of all zeros is a tag placeholder, not a year. Display only; the tag is kept.
  assert.match(read('ios/App/App/Domain/CatalogModels.swift'), /enum AeonAlbumYear/);
  assert.match(detail, /AeonAlbumYear\.display\(album\.year\)/);
  assert.match(library, /AeonAlbumYear\.display\(album\.year\)/);
  assert.doesNotMatch(library, /album\.year\.isEmpty/);
  // The album artist is not repeated on every track row.
  assert.match(detail, /private func trackArtist\(_ track: CatalogTrack\) -> String\?/);
  // Shelf covers have a fixed side; they are not sized from the row.
  assert.match(library, /albumGridCell\(album, side: width >= 700 \? 174 : 146\)/);
  assert.doesNotMatch(library, /GeometryReader \{ proxy in artwork/);
  // A breadcrumb label takes its width before the rule does.
  const crumb = component.split('struct AeonBreadcrumb: View')[1].split('enum AeonButtonTier')[0];
  assert.match(crumb, /Text\(text\.uppercased\(\)\)[^\n]*\.layoutPriority\(1\)/);
  // Storage is measured when it is looked at, counts both music roots, and never says "Zero KB".
  assert.match(settings, /storage-value"\)\n(\s*\/\/[^\n]*\n)*\s*\.onAppear \{ controller\.measureStorage\(\) \}/);
  assert.match(settings, /allowsNonnumericFormatting = false/);
  assert.doesNotMatch(settings, /ByteCountFormatter\.string\(/);
  const controller = read('ios/App/App/Features/Settings/SettingsController.swift');
  assert.match(controller, /"Aeon\/Media"/);
  assert.match(controller, /guard !measuringStorage else \{ return \}/);
  // Disclosure rows use the shared chevron.
  assert.match(component, /struct AeonDisclosureStyle: DisclosureGroupStyle/);
  assert.match(read('ios/App/App/Features/Player/EQView.swift'), /\.disclosureGroupStyle\(AeonDisclosureStyle\(\)\)/);
});

test('the iPad sidebar carries a mini player that fits inside it', () => {
  const bar = read('ios/App/App/Features/Player/PlayerBar.swift');
  const chrome = read('ios/App/App/DesignSystem/AeonChrome.swift');
  // One row of artwork, title and three 44-point buttons needs about 254 points; the
  // sidebar is 196. The overflow pushed the whole sidebar off the leading screen edge.
  const sidebar = chrome.split('private var sidebar: some View')[1].split('private func navigationButton')[0];
  assert.match(sidebar, /playerBar\.frame\(minHeight: AeonTheme\.Space\.playerBar\)\s*\.environment\(\\\.aeonPlayerBarNarrow, true\)/);
  assert.equal((chrome.match(/aeonPlayerBarNarrow/g) || []).length, 1);
  const narrow = bar.split('if narrow {')[1].split('} else {')[0];
  for (const control of ['openButton(presentation)', 'previousButton', 'toggleButton(snapshot)', 'nextButton']) assert.ok(narrow.includes(control), control);
  assert.match(narrow, /VStack\(alignment: \.leading/);
  assert.doesNotMatch(narrow, /PlayerBarSurface/);
});
