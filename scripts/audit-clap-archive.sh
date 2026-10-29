#!/bin/bash
# Archive audit: both CLAP models must be compiled into Tonearm.app itself,
# never an ODR asset pack. Run after `xcodebuild archive`, before upload.
# Usage: scripts/audit-clap-archive.sh [path/to/Tonearm.xcarchive]
set -euo pipefail

archive="${1:-./build/Tonearm.xcarchive}"
app="$archive/Products/Applications/Tonearm.app"

if [[ ! -d "$app" ]]; then
  echo "Archive audit: $app not found" >&2
  exit 1
fi

for model in CLAPAudioEncoder CLAPTextEncoder; do
  if ! find "$app" -type d -name "$model.mlmodelc" -print -quit | grep -q .; then
    echo "Archive audit: $model.mlmodelc missing from Tonearm.app" >&2
    exit 1
  fi
done

if find "$archive" -type d \( -name '*clap-audio*.assetpack' -o -name '*clap-text*.assetpack' \) -print -quit | grep -q .; then
  echo "CLAP must be bundled, not an ODR asset pack" >&2
  exit 1
fi

# Local archive sizes (KiB) — NOT Apple's device-thinned download size.
echo "Archive audit: local archive sizes in KiB (not Apple's final thinned download size)"
du -sk "$app"
du -sk "$(find "$app" -type d -name 'CLAPAudioEncoder.mlmodelc' -print -quit)"
du -sk "$(find "$app" -type d -name 'CLAPTextEncoder.mlmodelc' -print -quit)"
echo "Archive audit: OK"
