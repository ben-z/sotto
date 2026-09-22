#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Pass a booted, disposable iPhone simulator UUID}"
build=(-project iOS/Sotto.xcodeproj -scheme Sotto
  -destination "platform=iOS Simulator,id=$device"
  -derivedDataPath .build/ios CODE_SIGN_IDENTITY=-)
xcodebuild "${build[@]}" build-for-testing
xcrun simctl install "$device" .build/ios/Build/Products/Debug-iphonesimulator/Sotto.app
xcrun simctl privacy "$device" grant microphone dev.sotto.notes
# Keep location timestamps fresh for the full test suite.
xcrun simctl location "$device" start --speed=1 --interval=1 37.3349,-122.0090 37.3449,-122.0090
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
python3 scripts/seed-ios-fixture.py "$container"
result="${SOTTO_IOS_RESULT_PATH:-work/ios-tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
# A directory with a metadata filename produces a real read error.
unreadableFixture="$container/Documents/Recordings/zzz-unreadable.json"
mkdir "$unreadableFixture"
removeUnreadableFixture() {
  local currentContainer
  currentContainer="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
  rmdir "$currentContainer/Documents/Recordings/zzz-unreadable.json"
}
cleanup() {
  if [[ "$unreadablePending" == true ]]; then removeUnreadableFixture; fi
  xcrun simctl location "$device" clear
}
unreadablePending=true
trap cleanup EXIT
xcodebuild "${build[@]}" -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "${result%.xcresult}-opening-failure.xcresult" \
  -only-testing:SottoUITests/NotesUITests/testUnreadableNoteStopsLoading test-without-building
removeUnreadableFixture
unreadablePending=false
xcodebuild "${build[@]}" -test-timeouts-enabled YES \
  -skip-testing:SottoUITests/NotesUITests/testUnreadableNoteStopsLoading \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$result" test-without-building
