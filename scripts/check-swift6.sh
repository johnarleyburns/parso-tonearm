#!/usr/bin/env bash
set -euo pipefail
fail=0
if rg -n 'swift-tools-version: 5|swiftLanguageMode\(\.v[0-5]\)|SWIFT_VERSION: "[0-5]' Package.swift project.yml Tonearm.xcodeproj; then fail=1; fi
if rg -n 'SWIFT_VERSION = [0-5]' Tonearm.xcodeproj/project.pbxproj 2>/dev/null; then fail=1; fi
if ! rg -q 'SWIFT_STRICT_CONCURRENCY = complete' Tonearm.xcodeproj/project.pbxproj; then fail=1; fi
if ((fail)); then echo 'Swift 6 guard: FAILED' >&2; exit 1; fi
echo 'Swift 6 guard: OK'
