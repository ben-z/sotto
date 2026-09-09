#!/usr/bin/env python3
"""Rebuild approved icon assets offline, or check that committed exports are current."""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

DESIGN = pathlib.Path(__file__).resolve().parents[1]
REPO = DESIGN.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='Compare regenerated assets without changing the checkout')
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix='sotto-artwork-') as folder:
    work = pathlib.Path(folder)
    shutil.copytree(DESIGN / 'source', work / 'source')
    subprocess.run(['swift', 'source/build.swift'], cwd=work, check=True)
    subprocess.run(['iconutil', '-c', 'icns', 'app/macos/Sotto.iconset', '-o', 'app/macos/Sotto.icns'], cwd=work, check=True)
    subprocess.run(['swift', 'source/validate.swift'], cwd=work, check=True)
    subprocess.run(['swiftc', '-typecheck', str(DESIGN / 'integration/SottoStatusArtwork.swift')], check=True)
    pairs = [(work / 'app/macos/Sotto.icns', REPO / 'Resources/Sotto.icns')]
    for p in (work / 'status/png').glob('*.png'):
        if '@3x' not in p.name:
            pairs.append((p, REPO / 'Resources/SottoStatus' / p.name))
    for folder in ['masters', 'composer-layers', 'status/svg', 'Sotto.icon']:
        for p in (work / folder).rglob('*'):
            if p.is_file() and (p.suffix == '.svg' or folder == 'Sotto.icon'):
                pairs.append((p, DESIGN / p.relative_to(work)))
    catalog = work / 'catalogs/iOS/Assets.xcassets'
    for p in catalog.rglob('*'):
        if p.is_file(): pairs.append((p, REPO / 'iOS/Assets.xcassets' / p.relative_to(catalog)))
    outdated = []
    for source, target in pairs:
        if args.check:
            if not target.is_file() or source.read_bytes() != target.read_bytes():
                outdated.append(str(target.relative_to(REPO)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    if outdated:
        raise SystemExit('Missing or outdated generated artwork:\n' + '\n'.join(outdated))
    print(f'{"Checked" if args.check else "Updated"} {len(pairs)} production artwork files.')
