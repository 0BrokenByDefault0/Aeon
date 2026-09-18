// Source contracts only. Native and device tests must exercise Apple's actual folder UI.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {createHash} = require('node:crypto');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');
const picker = read('ios/App/App/Import/ImportPicker.swift');
const root = read('ios/App/App/Features/Root/AeonRootView.swift');
const unit = read('ios/App/AppTests/ImportPickerTests.swift');
const ui = read('ios/App/AppUITests/ImportPickerPresentationTests.swift');
const workflow = read('.github/workflows/ios-ipa.yml');
const session = picker.split('final class FolderPickerSession:')[1]?.split('struct FolderDocumentPicker')[0] || '';

test('folder uses Apples direct directory initializer while audio keeps copy mode', () => {
  assert.match(picker, /if kind == \.folder \{\s*controller = UIDocumentPickerViewController\(forOpeningContentTypes: \[\.folder\]\)/);
  assert.match(picker, /asCopy: kind\.copiesSelection/);
  assert.match(picker, /var copiesSelection: Bool \{ self == \.audioFiles \}/);
  assert.match(picker, /case \.folder: return \[\.folder\]/);
});

test('root owns one persistent folder session and leaves copied-file picker unchanged', () => {
  assert.match(root, /@StateObject private var folderPickerSession = FolderPickerSession\(\)/);
  assert.match(root, /if kind == \.folder \{[\s\S]*?FolderDocumentPicker\(session: folderPickerSession\)/);
  assert.match(root, /else \{\s*ImportDocumentPicker\(kind: kind, event: recordPickerEvent\)/);
  assert.match(root, /folderPickerSession\.begin\(event: recordPickerEvent\)/);
  assert.match(root, /acceptPickerOutcome\(outcome, kind: \.folder\)/);
});

test('folder session strongly retains controller beyond visual sheet dismissal', () => {
  assert.match(session, /private var currentController: UIDocumentPickerViewController\?/);
  assert.match(session, /currentController = controller/);
  assert.match(session, /func sheetDidDismiss\(\)[\s\S]*?sheet_dismissed_awaiting_callback/);
  const dismissed = session.split('func sheetDidDismiss()')[1]?.split('func documentPicker(')[0] || '';
  assert.doesNotMatch(dismissed, /currentController = nil|finished = true|active = false/);
  assert.match(root, /folderPickerSession\.sheetDidDismiss\(\)/);
});

test('folder callback entry precedes one-shot and stale-controller guards', () => {
  const callback = session.split('didPickDocumentsAt urls: [URL])')[1]?.split('didPickDocumentAt url: URL')[0] || '';
  assert(callback.indexOf('trace("callback.entered.') >= 0);
  assert(callback.indexOf('trace("callback.entered.') < callback.indexOf('guard active, !finished, controller === currentController'));
  assert.match(callback, /event\("received\.\\\(urls\.count\\\)"\)/);
  assert.match(callback, /finish\(\.picked\(urls\)\)/);
  assert.match(session, /didPickDocumentAt url: URL\)[\s\S]*?documentPicker\(controller, didPickDocumentsAt: \[url\]\)/);
});

test('unit regression models dismissal-before-delivery without system injection into production', () => {
  assert.match(unit, /testFolderSessionRetainsPickerAcrossSheetDismissalUntilSelectionArrives/);
  assert.match(unit, /session\.sheetDidDismiss\(\)/);
  assert.match(unit, /XCTAssertTrue\(session\.awaitingOutcome/);
  assert.match(unit, /session\.documentPicker\(controller, didPickDocumentsAt: \[chosen\]\)/);
  assert.match(unit, /XCTAssertEqual\(received, \[chosen\]\)/);
});

test('real folder UI regression uses the host accessibility tree and real confirmation', () => {
  assert.match(ui, /testFolderOpenImportsNestedAudioThroughSystemPicker/);
  assert.match(ui, /labels: \["Open", "Done"\], button: true/);
  assert.match(ui, /open\.tap\(\)/);
  assert.match(ui, /Added 1 track in 1 album to Library\./);
  const ext = ui.split('extension ImportPickerPresentationTests {')[1] || '';
  assert.doesNotMatch(ext, /documentManager\.debugDescription/);
  assert.doesNotMatch(ext, /didPickDocumentsAt|\.importURLs\(/);
});

test('all original picker presentation and cancellation tests remain byte-identical', () => {
  const original = ui.split('\nextension ImportPickerPresentationTests {')[0];
  const bytes = Buffer.from(original);
  const sha = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
  assert.equal(sha, '934e307695ac699260da8bc61983abfa5e7e2bfe');
});

test('IPA build numbering and upload-before-native ordering remain intact', () => {
  assert.match(workflow, /CURRENT_PROJECT_VERSION="\$GITHUB_RUN_NUMBER"/);
  assert(workflow.indexOf('- name: Upload fast IPA') < workflow.indexOf('- name: Capture orbital UI review'));
  assert(workflow.indexOf('- name: Upload fast IPA') < workflow.indexOf('- name: Run focused native validation'));
  assert.doesNotMatch(workflow, /continue-on-error/);
});
