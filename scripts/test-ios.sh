#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Pass a booted, disposable iPhone simulator UUID}"
build=(-project iOS/Sotto.xcodeproj -scheme Sotto
  -destination "platform=iOS Simulator,id=$device"
  -derivedDataPath .build/ios CODE_SIGN_IDENTITY=-)
testOptions=(-test-timeouts-enabled YES
  -default-test-execution-time-allowance 90
  -maximum-test-execution-time-allowance 120)
xcodebuild "${build[@]}" build-for-testing
xcrun simctl install "$device" .build/ios/Build/Products/Debug-iphonesimulator/Sotto.app
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
python3 scripts/seed-ios-fixture.py "$container" --long-list
result="${SOTTO_IOS_RESULT_PATH:-work/ios-tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
xcrun simctl privacy "$device" revoke microphone dev.sotto.notes
xcodebuild "${build[@]}" "${testOptions[@]}" \
  -resultBundlePath "${result%.xcresult}-microphone-denied.xcresult" \
  -only-testing:SottoUITests/NotesUITests/testMicrophoneDenialStaysVisibleWithLongHistory test-without-building
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
python3 scripts/seed-ios-fixture.py "$container"
xcrun simctl privacy "$device" grant microphone dev.sotto.notes
xcodebuild "${build[@]}" "${testOptions[@]}" \
  -resultBundlePath "${result%.xcresult}-playback-recovery.xcresult" \
  -only-testing:SottoUITests/NotesUITests/testCorruptAudioDoesNotBlockPlaybackOrRecording test-without-building
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
# A directory with a metadata filename produces a real read error.
unreadableFixture="$container/Documents/Recordings/000-unreadable.json"
mkdir "$unreadableFixture"
removeUnreadableFixture() {
  local currentContainer
  currentContainer="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
  rmdir "$currentContainer/Documents/Recordings/000-unreadable.json"
}
cleanup() {
  if [[ "$unreadablePending" == true ]]; then removeUnreadableFixture; fi
  xcrun simctl location "$device" clear
}
unreadablePending=true
trap cleanup EXIT
xcodebuild "${build[@]}" "${testOptions[@]}" \
  -resultBundlePath "${result%.xcresult}-opening-failure.xcresult" \
  -only-testing:SottoUITests/NotesUITests/testUnreadableNoteDoesNotBlockRecording test-without-building
removeUnreadableFixture
unreadablePending=false
# Each location check gets a fresh fix before launching its app.
for locationTest in testBackToBackRecordingsKeepTheirLocations testRecordEditAndRecoverWithoutKey; do
  xcrun simctl location "$device" set 37.3349,-122.0090
  xcodebuild "${build[@]}" "${testOptions[@]}" \
    -resultBundlePath "${result%.xcresult}-$locationTest.xcresult" \
    "-only-testing:SottoUITests/NotesUITests/$locationTest" test-without-building
done
# The real one-minute recording plus settings and relaunch checks need their own budget.
recordingLimitAllowance=180
xcodebuild "${build[@]}" -test-timeouts-enabled YES \
  -default-test-execution-time-allowance "$recordingLimitAllowance" \
  -maximum-test-execution-time-allowance "$recordingLimitAllowance" \
  -resultBundlePath "${result%.xcresult}-recording-limit.xcresult" \
  -only-testing:SottoUITests/NotesUITests/testRecordingLimitPersistsAndStopsAtCapturedDeadline test-without-building
xcodebuild "${build[@]}" "${testOptions[@]}" \
  -skip-testing:SottoUITests/NotesUITests/testCorruptAudioDoesNotBlockPlaybackOrRecording \
  -skip-testing:SottoUITests/NotesUITests/testMicrophoneDenialStaysVisibleWithLongHistory \
  -skip-testing:SottoUITests/NotesUITests/testUnreadableNoteDoesNotBlockRecording \
  -skip-testing:SottoUITests/NotesUITests/testBackToBackRecordingsKeepTheirLocations \
  -skip-testing:SottoUITests/NotesUITests/testRecordEditAndRecoverWithoutKey \
  -skip-testing:SottoUITests/NotesUITests/testRecordingLimitPersistsAndStopsAtCapturedDeadline \
  -resultBundlePath "$result" test-without-building
