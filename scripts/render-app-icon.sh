#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/Resources/IconSource/platterhead-icon.svg"
out="$root/Resources/Assets.xcassets/AppIcon.appiconset"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 "$source" -o "$out/AppIcon-1024.png"
elif command -v convert >/dev/null 2>&1; then
  if ! convert -background none "$source" -resize 1024x1024 "$out/AppIcon-1024.png" 2>/dev/null; then
    echo "ImageMagick could not render the local font; retaining the checked-in base icon." >&2
  fi
else
  echo "Install rsvg-convert or ImageMagick to render the app icon." >&2
  exit 1
fi
cp "$out/AppIcon-1024.png" "$out/AppIcon-1024-dark.png"
cp "$out/AppIcon-1024.png" "$out/AppIcon-1024-tinted.png"
