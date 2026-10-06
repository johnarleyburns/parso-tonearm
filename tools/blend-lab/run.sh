#!/usr/bin/env bash
# Renders the blend-lab test pairs. Needs ffmpeg and python3 with numpy.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
mkdir -p cache out
swiftc -O -o cache/decode-prep decode-prep/main.swift \
  "$ROOT/Sources/Domain/BuiltInTransitionPrepPack.swift" "$ROOT/Sources/Domain/DJTrackPrepPayload.swift"
PAIRS=(jamendo-1865162:jamendo-2153817:1-clean-grids
       jamendo-257447:jamendo-2186959:2-typical-grids
       jamendo-23560:jamendo-2299001:3-tempo-gap-4.6pct)
IDS=$(printf '%s\n' "${PAIRS[@]}" | awk -F: '{print $1; print $2}')
cache/decode-prep "$ROOT/Resources/Starter/starter-mac.sqlite" cache/candidates.json $IDS
python3 blend.py cache/candidates.json out cache "${PAIRS[@]}"
