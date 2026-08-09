#!/usr/bin/env bash
set -euo pipefail
fail=0
if grep -En 'swift-tools-version: 5|swiftLanguageMode\(\.v[0-5]\)|SWIFT_VERSION: "[0-5]' Package.swift project.yml Tonearm.xcodeproj/project.pbxproj >/dev/null; then fail=1; fi
if grep -En 'SWIFT_VERSION = [0-5]' Tonearm.xcodeproj/project.pbxproj >/dev/null 2>&1; then fail=1; fi
if ! grep -q 'SWIFT_STRICT_CONCURRENCY = complete' Tonearm.xcodeproj/project.pbxproj; then fail=1; fi
if ((fail)); then echo 'Swift 6 guard: FAILED' >&2; exit 1; fi
echo 'Swift 6 guard: OK'
