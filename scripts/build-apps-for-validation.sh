#!/usr/bin/env bash
# Compile generic device targets in CI, matching the shipped platforms.
# This requires device SDKs, not attached hardware or simulator runtimes.
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Never pass a global -sdk override: Tonearm embeds the watchOS application.
# Keep default device architectures, independent of the validation host's CPU.
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
    -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
    -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO
