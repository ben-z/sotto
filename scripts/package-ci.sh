#!/bin/zsh
# Packages the already-tested native app without Apple account credentials.
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/.build/ci/Sotto.app"
version=$(cat VERSION)
arch=$(uname -m)
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { print -u2 "Unsupported architecture: $arch"; exit 1; }
python3 scripts/check-bundle.py "$app"
# This path intentionally produces ad-hoc builds, never a notarized-release fallback.
codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc' || { print -u2 'Expected an ad-hoc CI build'; exit 1; }
[[ "$(lipo -archs "$app/Contents/MacOS/sotto")" == "$arch" ]] || { print -u2 'App does not match runner architecture'; exit 1; }
out="$PWD/.build/ci-download"
mkdir -p "$out"
name="Sotto-$version-macos-$arch.zip"
ditto -c -k --keepParent "$app" "$out/$name"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
ditto -x -k "$out/$name" "$temporary"
python3 scripts/check-bundle.py "$temporary/Sotto.app"
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
print "Packaged and extraction-tested: $out/$name"
