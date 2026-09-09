#!/usr/bin/env python3
"""Offline checks for an actual packaged app; never launches it or reads Keychain."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--universal', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with (args.app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleShortVersionString'] == (root / 'VERSION').read_text().strip()
assert info['CFBundleIdentifier'] == 'dev.sotto.app'
assert info['NSMicrophoneUsageDescription']
resources = args.app / 'Contents/Resources'
assert (resources / info['CFBundleIconFile']).is_file()
assert sorted(p.name for p in (resources / 'SottoStatus').iterdir()) == [
    'SottoGlyphTemplate.png', 'SottoGlyphTemplate@2x.png']
assert not list(args.app.rglob('*.swift')), 'Design or source files must not ship'
binary = args.app / 'Contents/MacOS' / info['CFBundleExecutable']
subprocess.run(['codesign', '--verify', '--strict', str(args.app)], check=True)
if args.universal:
    arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    assert set(arches) == {'arm64', 'x86_64'}, arches
subprocess.run([str(binary), '--help'], check=True, stdout=subprocess.DEVNULL)
print('Packaged app checks passed')
