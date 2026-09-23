const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const root = join(__dirname, '..');
const read = path => readFileSync(join(root, path), 'utf8');

const importer = read('ios/App/App/Import/LibraryImporter.swift');
const container = read('ios/App/App/AppContainer.swift');
const rootView = read('ios/App/App/Features/Root/AeonRootView.swift');
const components = read('ios/App/App/DesignSystem/AeonComponents.swift');
const workflow = read('.github/workflows/ios-ipa.yml');

test('official large-library flow adopts Aeons own Music directory in place', () => {
  assert.match(importer, /func adoptMusicLibrary\(/);
  assert.match(importer, /\[mediaStore\.documentsMusicRoot\]/);
  assert.match(importer, /mode: \.folder/);
  assert.match(importer, /scanPolicy: \.adoptedMusicRoot/);
  assert.match(importer, /if mediaStore\.adoptedDocumentReference\(for: source\) != nil \{ return source \}/);
});

test('adoption skips Aeon-managed internal music roots and hidden directories', () => {
  assert.match(importer, /isManagedMusicDirectory/);
  for (const name of ['_Imported', '_Migrated', '_Restored']) assert.ok(importer.includes(`"${name}"`));
  assert.match(importer, /isDirectory, name\.hasPrefix\("\."\)/);
});

test('folder grouping uses the actual leaf folder during recursive adoption', () => {
  assert.match(importer, /target\.deletingLastPathComponent\(\)\.lastPathComponent/);
  assert.match(importer, /folderKey: entry\.url\.deletingLastPathComponent\(\)\.standardizedFileURL\.path/);
});

test('UI exposes Files plus Adopt Library, not the broken external folder picker', () => {
  assert.match(components, /title: "Adopt Library"/);
  assert.match(components, /aeon\.library\.import\.adopt/);
  assert.match(components, /On My iPhone → ISOLATION → Music/);
  assert.doesNotMatch(components, /aeon\.library\.import\.folder/);
  assert.match(rootView, /adoptLibrary: \{ container\.adoptMusicLibrary\(\) \}/);
  assert.doesNotMatch(rootView, /folderImporterPresented|folder\.swiftui/);
});

test('adoption uses the existing import progress and result channels', () => {
  assert.match(container, /func adoptMusicLibrary\(\)/);
  assert.match(container, /library\.adopt\.started/);
  assert.match(container, /library\.adopt\.completed/);
  assert.match(container, /libraryImportProgress = LibraryImportProgress/);
  assert.match(container, /libraryImportResult = result/);
});


test('adopt rescan can conservatively repair moved collector-owned albums', () => {
  assert.match(importer, /repairAdoptedAlbumIfNeeded/);
  assert.match(importer, /matchingAlbums\(fields: fields, trackCount: playable\.count[,)]/);
  assert.match(importer, /repository\.updateTrack\(updated\)/);
  assert.match(importer, /!path\.hasPrefix\("Music\/_Imported\/"\)/);
  assert.match(importer, /!path\.hasPrefix\("Music\/_Migrated\/"\)/);
  assert.match(importer, /!path\.hasPrefix\("Music\/_Restored\/"\)/);
  assert.match(importer, /repairedTracks/);
});

test('IPA-first ordering and distinct build numbers remain intact', () => {
  assert.match(workflow, /CURRENT_PROJECT_VERSION="\$GITHUB_RUN_NUMBER"/);
  assert(workflow.indexOf('- name: Upload fast IPA') < workflow.indexOf('- name: Run focused native validation'));
  assert.doesNotMatch(workflow, /continue-on-error/);
});
