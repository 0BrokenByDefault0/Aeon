// Source-level regressions only. They do not press Open in the system picker.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');
const picker = read('ios/App/App/Import/ImportPicker.swift');
const root = read('ios/App/App/Features/Root/AeonRootView.swift');

test('audio copy policy is used by the production controller factory', () => {
  assert.match(picker, /var copiesSelection: Bool \{ self == \.audioFiles \}/);
  assert.match(picker, /let controller = Self\.makeController\(for: kind\)/);
  assert.match(picker, /asCopy: kind\.copiesSelection/);
  assert.match(picker, /controller\.delegate = context\.coordinator/);
});
test('picker completion remains one-shot and records receipt before handing it back', () => {
  const callback = picker.split('didPickDocumentsAt urls: [URL])')[1].split('func documentPickerWasCancelled')[0];
  assert(callback.indexOf('guard !finished') < callback.indexOf('finished = true'));
  assert(callback.indexOf('event("received.') < callback.indexOf('completion(.picked(urls))'));
  assert.match(callback, /guard !urls\.isEmpty/);
});
test('root processes receipt independently of the dismissal callback', () => {
  assert.match(root, /Task \{ @MainActor in\s*handle\(outcome, kind: kind\)/);
  assert.doesNotMatch(root, /pendingPickerOutcome/);
  const dismissal = root.split('private func completePickerDismissal()')[1].split('private func recordPickerEvent')[0];
  assert.doesNotMatch(dismissal, /handle\(|importLibrary\(/);
  assert.match(dismissal, /pickerIsVisible = false/);
});
test('folder grants remain retained, while fast result notices wait for dismissal', () => {
  assert.match(root, /if case \.picked\(let urls\) = outcome, !kind\.copiesSelection/);
  assert.match(root, /if progress == nil \{ sourceAccess = nil \}/);
  assert.match(root, /!pickerIsVisible && \(container\.libraryImportError != nil \|\| completedImport != nil\)/);
});
test('receipt and handoff diagnostics contain counts rather than private file paths', () => {
  assert.match(root, /recordPickerEvent\("handoff\.\\\(kind\.rawValue\)\.\\\(urls\.count\)"\)/);
  const log = root.split('private func recordPickerEvent')[1].split('private func handle')[0];
  assert.match(log, /diagnosticsLog\.record\(eventCode:/);
  assert.doesNotMatch(log, /filePath:|lastPathComponent|absoluteString/);
});
