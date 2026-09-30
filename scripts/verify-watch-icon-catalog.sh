#!/bin/bash
# Validate the Watch app icon with the platform it actually belongs to.
# The TonearmWatch target's icon is the watchOS circle (Icon Composer's 1088
# canvas) of the shared `Resources/AppIcon.icon`, compiled together with
# `WatchApp/Assets.xcassets`. A plain JSON/file-existence check is not enough:
# watchOS actool is the authority for whether `AppIcon` has applicable watchOS
# content, and it must write CFBundleIconName for the Watch app.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ -e WatchApp/Assets.xcassets/AppIcon.appiconset ]]; then
  echo "    FAIL: WatchApp/Assets.xcassets/AppIcon.appiconset must not exist; the Watch icon comes from Resources/AppIcon.icon and two icons named AppIcon clash." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find actool >/dev/null 2>&1; then
  echo "    SKIP (Xcode/actool is not installed)"
  exit 0
fi

actool=$(xcrun --find actool)
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/tonearm-watch-icons.XXXXXX")
trap 'rm -rf "$output_dir"' EXIT
mkdir "$output_dir/compiled"

"$actool" WatchApp/Assets.xcassets Resources/AppIcon.icon \
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

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$output_dir/asset-info.plist" 2>/dev/null || true)
if [[ "$icon_name" != "AppIcon" ]]; then
  echo "    FAIL: watchOS actool did not produce CFBundleIconName=AppIcon from Resources/AppIcon.icon; enable watchOS in Icon Composer." >&2
  exit 1
fi

echo "    OK (watchOS AppIcon compiles from AppIcon.icon)"
