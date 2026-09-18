const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {createHash} = require('node:crypto');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');
const picker = read('ios/App/App/Import/ImportPicker.swift');
const root = read('ios/App/App/Features/Root/AeonRootView.swift');
const ui = read('ios/App/AppUITests/ImportPickerPresentationTests.swift');
const workflow = read('.github/workflows/ios-ipa.yml');

test('folder uses exactly one root SwiftUI fileImporter', () => {
  assert.equal((root.match(/\.fileImporter\(/g) || []).length, 1);
  assert.match(root, /allowedContentTypes: \[\.folder\]/);
  assert.match(root, /allowsMultipleSelection: false/);
  assert.match(root, /@State private var folderImporterPresented = false/);
  assert.doesNotMatch(root, /FolderPickerSession|FolderDocumentPicker/);
});

test('file copy picker remains separate and unchanged in policy', () => {
  assert.match(picker, /var copiesSelection: Bool \{ self == \.audioFiles \}/);
  assert.match(picker, /asCopy: kind\.copiesSelection/);
  assert.match(root, /ImportDocumentPicker\(kind: kind, event: recordPickerEvent\)/);
  assert.match(root, /if kind == \.folder \{[\s\S]*?folderImporterPresented = true[\s\S]*?\} else \{\s*picker = kind/);
});

test('folder result acquires access and enters the existing importer handoff', () => {
  assert.match(root, /folder\.swiftui\.received/);
  assert.match(root, /acceptPickerOutcome\(\.picked\(urls\), kind: \.folder\)/);
  assert.match(root, /if case \.picked\(let urls\) = outcome, !kind\.copiesSelection \{\s*sourceAccess = ImportSourceAccess\(urls: urls\)/);
  assert.match(root, /case \.folder:\s*container\.importLibrary\(urls: urls, mode: \.folder\)/);
});

test('folder dismissal and failure are observable without private paths', () => {
  assert.match(root, /folder\.swiftui\.dismissed/);
  assert.match(root, /folder\.swiftui\.cancelled/);
  assert.match(root, /folder\.swiftui\.failed/);
  assert.doesNotMatch(root, /folder\.swiftui\.[^"\n]*lastPathComponent|folder\.swiftui\.[^"\n]*\.path/);
});

test('custom retained folder-host experiment is removed', () => {
  assert.doesNotMatch(picker, /FolderPickerHost|FolderPickerSession|FolderDocumentPicker/);
});

test('original picker presentation and cancellation coverage remains byte-identical', () => {
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
