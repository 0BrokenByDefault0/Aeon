#!/usr/bin/env python3
"""Update Aeon's web assets inside an existing unsigned Capacitor iOS shell.
This does not compile Swift or change native dependencies.
"""
import argparse
import hashlib
import plistlib
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('base', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True)
args = parser.parse_args()
if args.base.resolve() == args.output.resolve():
    parser.error('Base and output must be different files')
web = Path(__file__).resolve().parents[1] / 'app'
assets = {'Payload/App.app/public/' + p.relative_to(web).as_posix(): p.read_bytes()
          for p in web.rglob('*') if p.is_file()}
info_path = 'Payload/App.app/Info.plist'
with zipfile.ZipFile(args.base) as source:
    assert source.testzip() is None, 'Base archive is corrupt'
    assert not any('_CodeSignature/' in p or p.endswith('embedded.mobileprovision')
                   for p in source.namelist()), 'Use an unsigned base shell'
    info = plistlib.loads(source.read(info_path))
    assert info['CFBundleIdentifier'] == 'app.isolation.sky', 'Unexpected application identity'
    info['CFBundleShortVersionString'] = args.version
    info['CFBundleVersion'] = args.build
    updates = {**assets, info_path: plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)}
    with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as target:
        for entry in source.infolist():
            target.writestr(entry, updates.get(entry.filename, source.read(entry.filename)))
        for name in updates.keys() - set(source.namelist()):
            entry = zipfile.ZipInfo(name)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            target.writestr(entry, updates[name])
with zipfile.ZipFile(args.base) as source, zipfile.ZipFile(args.output) as target:
    assert target.testzip() is None
    for entry in source.infolist():
        assert target.read(entry.filename) == updates.get(entry.filename, source.read(entry.filename)), entry.filename
        assert target.getinfo(entry.filename).external_attr == entry.external_attr, entry.filename
    for name, data in assets.items():
        assert target.read(name) == data, name
    assert target.getinfo('Payload/App.app/App').external_attr >> 16 & 0o111
print(f'Verified {args.output.name}: {args.output.stat().st_size:,} bytes')
print('Native executable and frameworks unchanged; application identity preserved.')
print('SHA-256:', hashlib.sha256(args.output.read_bytes()).hexdigest())
