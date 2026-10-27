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
