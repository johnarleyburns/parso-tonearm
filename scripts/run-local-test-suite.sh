#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

IOS_DESTINATION="${TONEARM_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=${TONEARM_IOS_SIMULATOR_NAME:-iPhone 16}}"
WATCH_DESTINATION="${TONEARM_WATCH_TEST_DESTINATION:-platform=watchOS Simulator,name=${TONEARM_WATCH_SIMULATOR_NAME:-Watch-Large}}"
TEST_RESULTS_DIR="${TONEARM_TEST_RESULTS_DIR:-$PWD/.test-results}"

prepare_named_simulator() {
  local platform="$1"
  local name="$2"
  local udid
  udid="$(xcrun simctl list devices available | sed -nE "s/^[[:space:]]+${name// /\\ } \\(([A-F0-9-]+)\\).*/\\1/p" | head -1)"
  if [[ -z "$udid" ]]; then
    echo "Unable to find available ${platform} simulator named '${name}'" >&2
    return 1
  fi
  echo "==> preparing ${platform} simulator ${name} (${udid})"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
}

run_swift_tests() {
  echo "==> running Swift package tests"
  swift test
}

run_iphone_smoke() {
  echo "==> running iPhone UI smoke test on ${IOS_DESTINATION}"
  mkdir -p "$TEST_RESULTS_DIR"
  if [[ -z "${TONEARM_IOS_TEST_DESTINATION:-}" ]]; then
    prepare_named_simulator iOS "${TONEARM_IOS_SIMULATOR_NAME:-iPhone 16}"
  fi
  xcodebuild test \
    -project Tonearm.xcodeproj \
    -scheme Tonearm \
    -destination "$IOS_DESTINATION" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$TEST_RESULTS_DIR/iphone-smoke-$(date +%Y%m%d-%H%M%S).xcresult" \
    -only-testing:TonearmUITests/TonearmSmokeUITests
}

run_watch_smoke() {
  if ! rg -q '^[[:space:]]*WatchUITests:' project.yml; then
  echo "==> watch UI smoke test skipped; WatchUITests is not configured"
    return
  fi

  echo "==> running watch UI smoke test on ${WATCH_DESTINATION}"
  mkdir -p "$TEST_RESULTS_DIR"
  if [[ -z "${TONEARM_WATCH_TEST_DESTINATION:-}" ]]; then
    prepare_named_simulator watchOS "${TONEARM_WATCH_SIMULATOR_NAME:-Watch-Large}"
  fi
  xcodebuild test \
    -project Tonearm.xcodeproj \
    -scheme TonearmWatch \
    -destination "$WATCH_DESTINATION" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$TEST_RESULTS_DIR/watch-smoke-$(date +%Y%m%d-%H%M%S).xcresult" \
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
