#!/usr/bin/env python3
from pathlib import Path
import subprocess

PIN = '5a2a90eb78ad5e42757270ee4a9f86d56c1864fb'
assert subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip() == PIN

picker = Path('ios/App/App/Import/ImportPicker.swift')
p = picker.read_text()
old = 'let controller = UIDocumentPickerViewController(forOpeningContentTypes: kind.contentTypes, asCopy: false)'
new = 'let controller = UIDocumentPickerViewController(forOpeningContentTypes: kind.contentTypes, asCopy: kind != .catalogArchive)'
assert p.count(old) == 1
picker.write_text(p.replace(old, new))

root = Path('ios/App/App/Features/Root/AeonRootView.swift')
r = root.read_text()
assert r.count('    @State private var pendingImport: PendingImportSelection?\n') == 1
r = r.replace('    @State private var pendingImport: PendingImportSelection?\n', '')
assert r.count('.sheet(item: $picker, onDismiss: finishPickerDismissal) { kind in') == 1
r = r.replace('.sheet(item: $picker, onDismiss: finishPickerDismissal) { kind in', '.sheet(item: $picker) { kind in')
old_callback = '''            ImportDocumentPicker(kind: kind) { outcome in
                pendingImport = PendingImportSelection(kind: kind, outcome: outcome)
                picker = nil
            }'''
new_callback = '''            ImportDocumentPicker(kind: kind) { outcome in
                // File/folder pickers return app-owned copies in RC2, so begin the
                // import in the delegate callback instead of depending on a SwiftUI
                // sheet onDismiss callback that did not fire reliably on-device.
                handle(outcome, kind: kind)
                picker = nil
            }'''
assert r.count(old_callback) == 1
r = r.replace(old_callback, new_callback)
start = '''    private func finishPickerDismissal() {
        guard let selection = pendingImport else { return }
        pendingImport = nil
        withExtendedLifetime(selection) {
            handle(selection.outcome, kind: selection.kind)
        }
    }

'''
assert r.count(start) == 1
r = r.replace(start, '')
root.write_text(r)

# RC2 must be visibly distinguishable from RC1.
settings = Path('ios/App/App/Import/ImportPicker.swift')
s = settings.read_text()
assert s.count('return "Recovery 1 · \\(commit.prefix(8))"') == 1
settings.write_text(s.replace('return "Recovery 1 · \\(commit.prefix(8))"', 'return "Recovery 2 · \\(commit.prefix(8))"'))

subprocess.run(['git','diff','--check'], check=True)
for path in [picker, root]:
    subprocess.run(['xcrun','swiftc','-frontend','-parse',str(path)], check=True)
print('RC2 picker handoff prepared')
