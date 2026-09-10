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
xcrun simctl location "$device" set 37.3349,-122.0090
python3 scripts/seed-ios-fixture.py "$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
result="${SOTTO_IOS_RESULT_PATH:-work/ios-tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
xcodebuild "${build[@]}" -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$result" test-without-building
