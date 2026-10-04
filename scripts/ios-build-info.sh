#!/bin/bash
set -euo pipefail
repo="$(cd "${SRCROOT:?}/.." && pwd)"
revision="$(git -C "$repo" rev-parse --short=12 HEAD)"
status="$(git -C "$repo" status --porcelain --untracked-files=normal)"
if [[ -n "$status" ]]; then
    revision+="-dirty"
fi
plist="${DERIVED_FILE_DIR:?}/Sotto-Info.plist"
mkdir -p "$DERIVED_FILE_DIR"
cp "$SRCROOT/Info.plist" "$plist"
/usr/libexec/PlistBuddy -c "Add :SottoGitRevision string $revision" "$plist"
