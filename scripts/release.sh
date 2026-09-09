#!/bin/zsh
# Creates verified release files locally. Publishing is a separate workflow step.
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:---notarized}"
[[ $# -le 1 && ( "$mode" == --adhoc || "$mode" == --notarized ) ]] || { print -u2 'Usage: release.sh [--adhoc|--notarized]'; exit 1; }
if [[ "$mode" == --adhoc ]]; then
    export SOTTO_SIGNING_IDENTITY=-
else
: "${SOTTO_SIGNING_IDENTITY:?Missing Developer ID Application signing identity}"
: "${APPLE_ID:?Missing Apple ID for notarization}"
: "${APPLE_TEAM_ID:?Missing Apple team ID}"
: "${APPLE_APP_PASSWORD:?Missing Apple app-specific password}"
[[ "$SOTTO_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || { print -u2 'Release requires a Developer ID Application certificate'; exit 1; }
fi
version=$(cat VERSION)
[[ "${RELEASE_TAG:-v$version}" == "v$version" ]] || { print -u2 'Release tag does not match VERSION'; exit 1; }
export SOTTO_APP_PATH="$PWD/.build/distribution/Sotto.app"
export SOTTO_UNIVERSAL=1
scripts/build.sh
python3 scripts/check-bundle.py "$SOTTO_APP_PATH" --universal
codesign --verify --strict "$SOTTO_APP_PATH"
mkdir -p .build/distribution
if [[ "$mode" == --notarized ]]; then
upload="$PWD/.build/distribution/notarization.zip"
ditto -c -k --keepParent "$SOTTO_APP_PATH" "$upload"
xcrun notarytool submit "$upload" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --output-format json > .build/distribution/notarization.json
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('.build/distribution/notarization.json').read_text())
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization failed: ' + str(result))
PY
xcrun stapler staple "$SOTTO_APP_PATH"
xcrun stapler validate "$SOTTO_APP_PATH"
spctl --assess --type execute --verbose=2 "$SOTTO_APP_PATH"
fi
archive="$PWD/.build/distribution/Sotto-$version-macOS-universal.zip"
ditto -c -k --keepParent "$SOTTO_APP_PATH" "$archive"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
ditto -x -k "$archive" "$temporary"
python3 scripts/check-bundle.py "$temporary/Sotto.app" --universal
(cd .build/distribution && shasum -a 256 "${archive:t}" > SHA256SUMS)
print "Release files: $archive"
