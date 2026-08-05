#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

IOS_DESTINATION="${TONEARM_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=${TONEARM_IOS_SIMULATOR_NAME:-iPhone 16}}"
WATCH_DESTINATION="${TONEARM_WATCH_TEST_DESTINATION:-platform=watchOS Simulator,name=${TONEARM_WATCH_SIMULATOR_NAME:-Watch-Large}}"

run_swift_tests() {
  echo "==> running Swift package tests"
  swift test
}

run_iphone_smoke() {
  echo "==> running iPhone UI smoke test on ${IOS_DESTINATION}"
  xcodebuild test \
    -project Tonearm.xcodeproj \
    -scheme Tonearm \
    -destination "$IOS_DESTINATION" \
    -only-testing:TonearmUITests/TonearmSmokeUITests
}

run_watch_smoke() {
  if ! rg -q '^[[:space:]]*WatchUITests:' project.yml; then
    echo "==> watch UI smoke test skipped; WatchUITests is not configured"
    return
  fi

  echo "==> running watch UI smoke test on ${WATCH_DESTINATION}"
  xcodebuild test \
    -project Tonearm.xcodeproj \
    -scheme TonearmWatch \
    -destination "$WATCH_DESTINATION" \
    -only-testing:WatchUITests/WatchSmokeUITests
}

run_ui_smoke_tests() {
  scripts/verify-ui-smoke-tests.sh
  run_iphone_smoke
  run_watch_smoke
}

case "${1:-full}" in
  swift)
    run_swift_tests
    ;;
  ui)
    run_ui_smoke_tests
    ;;
  full)
    run_swift_tests
    run_ui_smoke_tests
    ;;
  *)
    echo "Usage: $0 [swift|ui|full]" >&2
    exit 2
    ;;
esac
