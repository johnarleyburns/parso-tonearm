#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TEST_LOCK_FILE="${TONEARM_TEST_LOCK_FILE:-${TMPDIR:-/tmp}/tonearm-local-test-suite.lock}"

acquire_test_lock() {
  while ! shlock -f "$TEST_LOCK_FILE" -p "$$"; do
    echo "==> another local test runner is active; waiting for it to finish"
    sleep 1
  done
  trap 'rm -f "$TEST_LOCK_FILE"' EXIT
}

acquire_test_lock

run_swift_tests() {
  echo "==> running Swift package tests"
  swift test
}

case "${1:-full}" in
  swift|full)
    run_swift_tests
    ;;
  *)
    echo "Usage: $0 [swift|full]" >&2
    exit 2
    ;;
esac
