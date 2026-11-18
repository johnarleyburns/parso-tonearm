#!/usr/bin/env bash
# Hermetic production-flow + visual regression harness (issue #80): `make tonearm-production-regression`.
# No Docker, network, model download, signing secrets or device. Runs the TonearmProductionRegressionTests
# target in the foreground and exits non-zero on any production-flow, adapter-call, accessibility,
# lease or baseline-render failure. Artifacts (actual render + diff) go to $TONEARM_HARNESS_ARTIFACT_DIR.
# `TONEARM_HARNESS_RECORD=1` rewrites baselines; review the git diff before committing it.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export TONEARM_HARNESS_ARTIFACT_DIR="${TONEARM_HARNESS_ARTIFACT_DIR:-$PWD/.build/production-regression-artifacts}"
rm -rf "$TONEARM_HARNESS_ARTIFACT_DIR"
mkdir -p "$TONEARM_HARNESS_ARTIFACT_DIR"
echo "==> Production regression harness (artifacts: $TONEARM_HARNESS_ARTIFACT_DIR)"
if ! swift test --filter TonearmProductionRegressionTests 2>&1 | tee "$TONEARM_HARNESS_ARTIFACT_DIR/harness.log"; then
  echo "Production regression FAILED; see $TONEARM_HARNESS_ARTIFACT_DIR" >&2
  exit 1
fi
grep -qE "Test run with [1-9][0-9]* tests? in [0-9]+ suites? passed" "$TONEARM_HARNESS_ARTIFACT_DIR/harness.log" \
  || { echo "Production regression executed no passing tests" >&2; exit 1; }
