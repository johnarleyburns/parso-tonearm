#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

check_ui_dir() {
  local dir="$1"
  local device="$2"

  if [ ! -d "$dir" ]; then
    echo "Missing $device UI test directory: $dir" >&2
    exit 1
  fi

  local tests
  tests="$(rg -n '^[[:space:]]*func test[A-Za-z0-9_]*[[:space:]]*\(' "$dir" || true)"
  local count
  count="$(printf '%s\n' "$tests" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$count" != "1" ]; then
    echo "$device must have exactly one UI smoke test; found $count in $dir:" >&2
    printf '%s\n' "$tests" >&2
    exit 1
  fi

  if ! printf '%s\n' "$tests" | rg -q 'Smoke'; then
    echo "$device UI test method must be named as a smoke test:" >&2
    printf '%s\n' "$tests" >&2
    exit 1
  fi
}

check_ui_dir "UITests" "iPhone"

if rg -q '^[[:space:]]*WatchUITests:' project.yml; then
  check_ui_dir "WatchUITests" "watch"
fi

if rg -q '^[[:space:]]*[A-Za-z0-9_]*Mac[A-Za-z0-9_]*UITests:|platform:[[:space:]]*macOS' project.yml; then
  check_ui_dir "MacUITests" "macOS"
fi

echo "UI smoke-test shape OK"
