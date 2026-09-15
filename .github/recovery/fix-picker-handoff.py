#!/usr/bin/env python3
from pathlib import Path
import subprocess

picker = Path('ios/App/App/Import/ImportPicker.swift')
p = picker.read_text()
old = '''        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: kind.contentTypes,
            asCopy: false
        )'''
new = '''        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: kind.contentTypes,
            asCopy: kind != .catalogArchive
        )'''
if old in p:
    p = p.replace(old, new, 1)
elif new not in p:
    raise AssertionError('Unexpected document picker construction')
picker.write_text(p)

root = Path('ios/App/App/Features/Root/AeonRootView.swift')
r = root.read_text()
r = r.replace('    @State private var pendingImport: PendingImportSelection?\n', '')
r = r.replace('.sheet(item: $picker, onDismiss: finishPickerDismissal) { kind in', '.sheet(item: $picker) { kind in')
old_callback = '''            ImportDocumentPicker(kind: kind) { outcome in
                pendingImport = PendingImportSelection(kind: kind, outcome: outcome)
                picker = nil
            }'''
new_callback = '''            ImportDocumentPicker(kind: kind) { outcome in
                // File/folder picks are app-owned copies in RC2. Start the import in
                // the delegate callback instead of waiting for sheet onDismiss.
                handle(outcome, kind: kind)
                picker = nil
            }'''
if old_callback in r:
    r = r.replace(old_callback, new_callback, 1)
elif new_callback not in r:
    raise AssertionError('Unexpected picker callback')
old_finish = '''    private func finishPickerDismissal() {
        guard let selection = pendingImport else { return }
        pendingImport = nil
        withExtendedLifetime(selection) {
            handle(selection.outcome, kind: selection.kind)
        }
    }

'''
r = r.replace(old_finish, '')
root.write_text(r)

s = picker.read_text()
s = s.replace('return "Recovery 1 · \\(commit.prefix(8))"', 'return "Recovery 2 · \\(commit.prefix(8))"')
picker.write_text(s)

subprocess.run(['git','diff','--check'], check=True)
for path in [picker, root]:
    subprocess.run(['xcrun','swiftc','-frontend','-parse',str(path)], check=True)
print('RC2 picker handoff prepared')
