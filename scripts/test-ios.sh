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
# Traversing 125 history rows and the real one-minute recording need a longer allowance.
longTestAllowance=180
longTestOptions=(-test-timeouts-enabled YES
  -default-test-execution-time-allowance "$longTestAllowance"
  -maximum-test-execution-time-allowance "$longTestAllowance")
# CoreSimulator can briefly report the XCTest runner as busy during installation.
# Retry only a failed launch before any test starts, since tests can mutate fixtures.
runUITests() (
  local resultPath="$1"
  shift
  local log status
  log="$(mktemp)"
  trap 'rm -f "$log"' EXIT
  if xcodebuild "${build[@]}" -resultBundlePath "$resultPath" "$@" test-without-building 2>&1 | tee "$log"; then
    return 0
  else
    status=$?
  fi
  if [[ "$status" != 65 ]] ||
    ! grep -Fq 'Application "dev.sotto.notes.uitests.xctrunner" is installing or uninstalling, and cannot be launched.' "$log" ||
    grep -Eq '^Test Case .+ started\.' "$log"; then
    return "$status"
  fi
  echo 'The simulator test runner was busy. Retrying once.'
  xcodebuild "${build[@]}" -resultBundlePath "${resultPath%.xcresult}-retry.xcresult" "$@" test-without-building
)
xcodebuild "${build[@]}" build-for-testing
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/ios/Build/Products/Debug-iphonesimulator/Sotto.app/Info.plist)" = "$(cat VERSION)"
xcrun simctl install "$device" .build/ios/Build/Products/Debug-iphonesimulator/Sotto.app
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
result="${SOTTO_IOS_RESULT_PATH:-work/ios-tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
python3 scripts/seed-ios-fixture.py "$container" --paged-history
xcrun simctl privacy "$device" grant microphone dev.sotto.notes
runUITests "${result%.xcresult}-paged-history.xcresult" "${longTestOptions[@]}" \
  -only-testing:SottoUITests/NotesUITests/testHistoryLoadsOnlyAsTheListScrolls
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
python3 scripts/seed-ios-fixture.py "$container" --long-list
xcrun simctl privacy "$device" revoke microphone dev.sotto.notes
runUITests "${result%.xcresult}-microphone-denied.xcresult" "${testOptions[@]}" \
  -only-testing:SottoUITests/NotesUITests/testMicrophoneDenialStaysVisibleWithLongHistory
container="$(xcrun simctl get_app_container "$device" dev.sotto.notes data)"
python3 scripts/seed-ios-fixture.py "$container"
xcrun simctl privacy "$device" grant microphone dev.sotto.notes
runUITests "${result%.xcresult}-playback-recovery.xcresult" "${testOptions[@]}" \
  -only-testing:SottoUITests/NotesUITests/testCorruptAudioDoesNotBlockPlaybackOrRecording
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
runUITests "${result%.xcresult}-opening-failure.xcresult" "${testOptions[@]}" \
  -only-testing:SottoUITests/NotesUITests/testUnreadableNoteDoesNotBlockRecording
removeUnreadableFixture
unreadablePending=false
# Each location check gets a fresh fix before launching its app.
for locationTest in testBackToBackRecordingsKeepTheirLocations testRecordEditAndRecoverWithoutKey; do
  xcrun simctl location "$device" set 37.3349,-122.0090
  runUITests "${result%.xcresult}-$locationTest.xcresult" "${testOptions[@]}" \
    "-only-testing:SottoUITests/NotesUITests/$locationTest"
done
runUITests "${result%.xcresult}-recording-limit.xcresult" "${longTestOptions[@]}" \
  -only-testing:SottoUITests/NotesUITests/testRecordingLimitPersistsAndStopsAtCapturedDeadline
runUITests "$result" "${testOptions[@]}" \
  -skip-testing:SottoUITests/NotesUITests/testCorruptAudioDoesNotBlockPlaybackOrRecording \
  -skip-testing:SottoUITests/NotesUITests/testMicrophoneDenialStaysVisibleWithLongHistory \
  -skip-testing:SottoUITests/NotesUITests/testUnreadableNoteDoesNotBlockRecording \
  -skip-testing:SottoUITests/NotesUITests/testBackToBackRecordingsKeepTheirLocations \
  -skip-testing:SottoUITests/NotesUITests/testRecordEditAndRecoverWithoutKey \
  -skip-testing:SottoUITests/NotesUITests/testRecordingLimitPersistsAndStopsAtCapturedDeadline \
  -skip-testing:SottoUITests/NotesUITests/testHistoryLoadsOnlyAsTheListScrolls
