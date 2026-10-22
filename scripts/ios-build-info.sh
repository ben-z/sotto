#!/bin/bash
set -euo pipefail
repo="$(cd "${SRCROOT:?}/.." && pwd)"
version="$(cat "$repo/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be major.minor.patch' >&2; exit 1; }
revision="$(git -C "$repo" rev-parse --short=12 HEAD)"
status="$(git -C "$repo" status --porcelain --untracked-files=normal)"
if [[ -n "$status" ]]; then
    revision+="-dirty"
fi
plist="${DERIVED_FILE_DIR:?}/Sotto-Info.plist"
mkdir -p "$DERIVED_FILE_DIR"
cp "$SRCROOT/Info.plist" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :SottoGitRevision string $revision" "$plist"
