#!/usr/bin/env bash
# Single source of truth for PR validation. Used by the PR Swift Validation
# workflow, the issue agent and the repair agent so the three cannot drift.
# Runs the same headless structural and Swift package checks as the repository CI.
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

step() { echo "::group::$*"; echo "=== $* ==="; }
endstep() { echo "::endgroup::"; }

step "Shell syntax"
while IFS= read -r f; do
  bash -n "$f" || { echo "Shell syntax error: $f" >&2; exit 1; }
done < <(git ls-files '*.sh')
endstep

step "Workflow YAML"
while IFS= read -r f; do
  ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$f" \
    || { echo "Invalid workflow YAML: $f" >&2; exit 1; }
done < <(git ls-files '.github/workflows/*.yml')
endstep

step "Automation regression tests"
bash scripts/tests/test-issue-pr-policy.sh
bash scripts/tests/test-issue-backlog-order.sh
bash scripts/tests/test-issue-backlog-author.sh
bash scripts/tests/test-release-repair-policy.sh
bash scripts/tests/test-clap-candidate-workflow.sh
bash scripts/tests/test-testflight-delivery-body.sh
bash scripts/tests/test-testflight-reconciler-discovery.sh
bash scripts/tests/test-production-regression-wiring.sh
if [[ -f scripts/tests/test-pr-maintenance.sh && -f .github/scripts/pr-maintenance.sh ]]; then
  bash scripts/tests/test-pr-maintenance.sh
fi
endstep

[[ "${1:-}" == "--fast" ]] && exit 0

step "Structural guards"
if ! command -v rg >/dev/null; then
  brew install ripgrep
fi
bash scripts/check-ci-guards.sh
endstep

step "Mood starter data"
make starter
endstep

step "Production regression harness"
bash scripts/run-production-regression.sh
endstep

step "Swift package tests"
swift test
endstep

step "Repository hygiene"
git diff --check
endstep

# Everything from here on regenerates Tonearm.xcodeproj via `make project`
# (XcodeGen), which rewrites project.pbxproj and the OAuth-credentials
# overlay in the working tree — it must run after "Repository hygiene" so
# that unrelated, expected churn never trips git diff --check.

step "Select stable Xcode"
# release-repair.yml does not select Xcode before calling this script,
# unlike pr-validation.yml; select it here so a real build is possible
# regardless of caller.
XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode_*.app' ! -iname '*beta*' ! -iname '*rc*' -print | sort -V | tail -1)
test -n "$XCODE"
sudo xcode-select -s "$XCODE"
xcodebuild -version
endstep

step "Regenerate Xcode project"
# The committed Tonearm.xcodeproj is a convenience snapshot, not the
# authoritative build input: even the real archive job (ios.yml
# testflight-build) regenerates it with `make project` before building,
# because it also writes the gitignored OAuth-credentials source file
# (Sources/Features/Ingest/GeneratedOAuthCredentials.swift) and the Core ML
# model-overlay YAML that project.yml's sources list depends on. A bare
# `xcodebuild build` against the stale checked-in project fails with
# "Build input files cannot be found" for that generated file and for any
# source file project.pbxproj still references after it was deleted.
if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi
make project
endstep

step "iOS + watchOS build (Tonearm.xcodeproj)"
# A cross-target compile error (e.g. in a Watch-only file) is invisible to
# `swift test` alone, since the Watch app is not part of the SwiftPM package.
# Build both app schemes for real. Per CLAUDE.md: never pass a global -sdk
# override to the combined Tonearm scheme.
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
endstep
