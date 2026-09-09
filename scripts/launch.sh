#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test -x .build/Sotto.app/Contents/MacOS/sotto || { print -u2 'Run scripts/build.sh first.'; exit 1; }
# Startup validates configuration and credentials. Missing Accessibility access
# is shown by the app, with Settings available to repair it; recording is blocked.
open "$PWD/.build/Sotto.app"
