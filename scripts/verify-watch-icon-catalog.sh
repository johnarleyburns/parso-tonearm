#!/bin/bash
# Validate the Watch app icon catalog with the platform it actually belongs to.
# A plain JSON/file-existence check is not enough: actool is the authority for
# whether AppIcon has applicable watchOS content.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find actool >/dev/null 2>&1; then
  echo "    SKIP (Xcode/actool is not installed)"
  exit 0
fi

actool=$(xcrun --find actool)
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/tonearm-watch-icons.XXXXXX")
trap 'rm -rf "$output_dir"' EXIT
mkdir "$output_dir/compiled"

"$actool" WatchApp/Assets.xcassets \
  --compile "$output_dir/compiled" \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --export-dependency-info "$output_dir/dependencies" \
  --output-partial-info-plist "$output_dir/asset-info.plist" \
  --app-icon AppIcon \
  --compress-pngs \
  --enable-on-demand-resources YES \
  --development-region en \
  --target-device watch \
  --minimum-deployment-target 11.0 \
  --platform watchos

echo "    OK (watchOS AppIcon catalog compiles)"
