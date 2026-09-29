#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/Resources/IconSource/platterhead-icon.svg"
out="$root/Resources/Assets.xcassets/AppIcon.appiconset"
if command -v rsvg-convert >/dev/null 2>&1; then
  rendered="$out/AppIcon-1024-rendered.png"
  rsvg-convert -w 1024 -h 1024 "$source" -o "$rendered"
  convert "$rendered" -background '#090a0d' -alpha remove -alpha off "$out/AppIcon-1024.png"
  rm -f "$rendered"
elif command -v convert >/dev/null 2>&1; then
  # App Store Connect rejects the 1024 px marketing icon when it has an alpha
  # channel. The SVG has rounded corners, so render it over the icon's dark
  # field and explicitly remove alpha before writing the catalog PNG.
  if ! convert -background '#090a0d' "$source" -resize 1024x1024 \
      -alpha remove -alpha off "$out/AppIcon-1024.png" 2>/dev/null; then
    echo "ImageMagick could not render the local font; retaining the checked-in base icon." >&2
  fi
else
  echo "Install rsvg-convert or ImageMagick to render the app icon." >&2
  exit 1
fi
cp "$out/AppIcon-1024.png" "$out/AppIcon-1024-dark.png"
cp "$out/AppIcon-1024.png" "$out/AppIcon-1024-tinted.png"
