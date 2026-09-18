// Source contracts only. The native picker test must press Apple's Open button.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {createHash} = require('node:crypto');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');
const picker = read('ios/App/App/Import/ImportPicker.swift');
const ui = read('ios/App/AppUITests/ImportPickerPresentationTests.swift');
const workflow = read('.github/workflows/ios-ipa.yml');
const host = picker.split('final class FolderPickerHost:')[1] || '';

test('only folder selection uses the retained UIKit presenter', () => {
  assert.match(picker, /if kind == \.folder \{\s*return FolderPickerHost\(picker: controller, event: event, completion: completion\)/);
  assert.match(picker, /controller\.delegate = context\.coordinator/);
  assert.match(picker, /var copiesSelection: Bool \{ self == \.audioFiles \}/);
  assert.match(picker, /case \.folder: return \[\.folder\]/);
  assert.match(picker, /asCopy: kind\.copiesSelection/);
});

test('folder host is the delegate and owns the child picker until the sheet ends', () => {
  assert.match(host, /UIViewController, UIDocumentPickerDelegate/);
  assert.match(host, /private\(set\) var picker: UIDocumentPickerViewController/);
  assert.match(host, /picker\.delegate = self/);
  assert.match(host, /override func viewDidAppear/);
  assert.match(host, /present\(picker, animated: false\)/);
  assert.doesNotMatch(host, /asyncAfter|startAccessingSecurityScopedResource|\.importURLs\(/);
});

test('callback entry is logged before the duplicate guard, with legacy delivery forwarded', () => {
  const callback = host.split('didPickDocumentsAt urls: [URL])')[1]?.split('func documentPickerWasCancelled')[0] || '';
  assert(callback.indexOf('trace("callback.entered.') >= 0);
  assert(callback.indexOf('trace("callback.entered.') < callback.indexOf('guard controller === picker, !finished'));
  assert.match(callback, /event\("received\.\\\(urls\.count\)"\)/);
  assert.match(callback, /finish\(\.picked\(urls\)\)/);
  assert.match(callback, /didPickDocumentAt url: URL\)[\s\S]*?documentPicker\(controller, didPickDocumentsAt: \[url\]\)/);
});

test('late delivery remains possible after child disappearance, without silent success', () => {
  const appeared = host.split('override func viewDidAppear')[1]?.split('private func presentPicker')[0] || '';
  assert.match(appeared, /returned_without_result/);
  assert.doesNotMatch(appeared, /finish\(|finished = true/);
  assert.match(host, /aeon\.import\.folder\.retry/);
  assert.match(host, /aeon\.import\.folder\.cancel/);
  assert.match(host, /private func finish[\s\S]*?guard !finished[\s\S]*?finished = true[\s\S]*?completion\(outcome\)/);
});

test('the real folder UI regression starts with only a DEBUG source, not catalogue records', () => {
  const fixture = host.split('#if DEBUG\n    /// Generate only a source file')[1] || '';
  assert.match(fixture, /Nested Record/);
  assert.match(fixture, /01 Folder Check\.wav/);
  assert.doesNotMatch(fixture, /insertAlbum|\.importURLs\(|PlaybackFixtureCoordinator/);
  assert.match(ui, /testFolderOpenImportsNestedAudioThroughSystemPicker/);
  assert.match(ui, /label: "Open", button: true/);
  assert.match(ui, /open\.tap\(\)/);
  assert.match(ui, /Added 1 track in 1 album to Library\./);
  assert.match(ui, /XCTAssertEqual\(count\.label, "1 ALBUM"\)/);
  assert.doesNotMatch(ui, /didPickDocumentsAt|\.importURLs\(/);
});

test('all original picker presentation and cancellation tests remain byte-identical', () => {
  const original = ui.split('\nextension ImportPickerPresentationTests {')[0];
  const bytes = Buffer.from(original);
  const sha = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
  assert.equal(sha, '934e307695ac699260da8bc61983abfa5e7e2bfe');
});

test('IPA internal build number tracks CI without moving native tests ahead of upload', () => {
  assert.match(workflow, /CURRENT_PROJECT_VERSION="\$GITHUB_RUN_NUMBER"/);
  assert(workflow.indexOf('- name: Upload fast IPA') < workflow.indexOf('- name: Capture orbital UI review'));
  assert(workflow.indexOf('- name: Upload fast IPA') < workflow.indexOf('- name: Run focused native validation'));
  assert.doesNotMatch(workflow, /continue-on-error/);
});
