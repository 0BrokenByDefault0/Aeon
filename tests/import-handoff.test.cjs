// Source contracts only; device decoding/import/playback is exercised by ImportPickerTests.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');
const importer = read('ios/App/App/Import/LibraryImporter.swift');
const picker = read('ios/App/App/Import/ImportPicker.swift');
const root = read('ios/App/App/Features/Root/AeonRootView.swift');
const native = read('ios/App/AppTests/ImportPickerTests.swift');

test('provider access is acquired before dismissal and released after import progress ends', () => {
  assert(root.indexOf('sourceAccess = ImportSourceAccess(urls: urls)') < root.indexOf('pendingPickerOutcome = (kind, outcome)'));
  assert.match(root, /\.sheet\(item: \$picker, onDismiss: completePickerDismissal\)/);
  assert.match(root, /onChange\(of: container\.libraryImportProgress\)[\s\S]*?if progress == nil \{ sourceAccess = nil \}/);
  assert.match(picker, /seen\.insert\(\$0\)\.inserted \}\.filter\(begin\)/);
  assert.match(picker, /deinit \{ accessed\.forEach\(end\) \}/);
});

test('async metadata reads use a coordinated local copy, while grouping retains original folders', () => {
  assert.match(importer, /coordinator\.coordinate\(readingItemAt: source, options: \[\], error: &coordinationError\) \{ coordinatedURL in/);
  assert.match(importer, /copyItem\(at: coordinatedURL, to: destination\)/);
  assert.match(importer, /tagReader\.read\(url: localURL, includeArtwork: false\)/);
  assert.match(importer, /folderKey: entry\.url\.deletingLastPathComponent/);
  assert.match(importer, /adoptedDocumentReference\(for: source\) != nil \{ return source \}/);
  assert.match(importer, /defer \{ try\? fileManager\.removeItem\(at: stagingRoot\) \}/);
  assert.match(importer, /catch LibraryImportError\.cancelled \{\s*throw LibraryImportError\.cancelled/);
});

test('zero-track, duplicate and partial outcomes are not silently discarded', () => {
  assert.match(importer, /No tracks were imported\./);
  assert.match(importer, /already in your Library/);
  assert.match(importer, /result\.recordFailure\(originalURLs\[candidate\.url\]/);
  assert.match(importer, /stage: "could not save the audio", error: error/);
  assert.match(root, /completedImport\?\.userMessage/);
  assert.match(root, /onReceive\(container\.\$libraryImportResult\) \{ completedImport = \$0 \}/);
});

test('successful imports route to a refreshed Library without starting unsolicited playback', () => {
  const receiver = root.split('.onReceive(container.$libraryImportResult) { result in')[1].split('.onAppear')[0];
  assert.match(receiver, /result\.importedTracks > 0/);
  assert.match(receiver, /libraryController\.reload\(reset: true\)/);
  assert.match(receiver, /libraryController\.setQuery\(""\)/);
  assert.match(receiver, /destination = \.library/);
  assert.doesNotMatch(receiver, /\.play\(/);
});

test('the new native regression uses real MP3 bytes and the production engine, not seeded playback', () => {
  assert.match(native, /audio\/tone-48000\.mp3/);
  assert.match(native, /AppServices\.production\(roots: roots, startSpectrum: false, startPlayback: true\)/);
  assert.match(native, /delegate\.documentPicker\(picker, didPickDocumentsAt: \[selected\]\)/);
  assert.match(native, /services\.libraryImporter\.importURLs\(returnedURLs, mode: \.single\)/);
  assert.match(native, /XCTAssertEqual\(try Data\(contentsOf: saved\), bytes\)/);
  assert.match(native, /removeItem\(at: selected\)/);
  assert.match(native, /services\.playbackCoordinator\.play\(completion:/);
  assert.match(native, /XCTAssertGreaterThan\(observedPosition, 0\.01/);
  assert.doesNotMatch(native, /PlaybackFixtureCoordinator|StubProbe|StubTagReader/);
});
