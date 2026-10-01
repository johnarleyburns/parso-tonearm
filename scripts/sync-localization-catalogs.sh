#!/usr/bin/env bash
# Extracts every localizable string with the Swift compiler (SWIFT_EMIT_LOC_STRINGS)
# and syncs the String Catalogs, exactly as Xcode does when it builds.
#
# Run this after adding or changing UI text. New keys arrive with no
# translations; add them in all seven catalog locales with state `needs_review`,
# and let a native speaker flip them to `translated` in Xcode's catalog editor
# (docs/l10n/REVIEW.md). Never copy the English text into another language as a
# placeholder.
#
# Resources/Localizable.xcstrings is shared: the app target compiles it, and
# the TonearmCore package bundles the same file, so package code looks it up
# with `bundle: .module`. TonearmDiscovery has its own catalog.
#
# Builds sequentially (iOS, then watchOS) like every other xcodebuild here —
# do not run it while another build is active.
set -euo pipefail
cd "$(dirname "$0")/.."

derived_data="${TONEARM_L10N_DERIVED_DATA:-/tmp/tonearm-l10n}"
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO -quiet

stringsdata() {
  find "$derived_data/Build/Intermediates.noindex" -path "*/Debug-*/$1.build/*" -name '*.stringsdata'
}

# shellcheck disable=SC2046 # one argument per .stringsdata file is intended
xcrun xcstringstool sync Resources/Localizable.xcstrings Resources/AppShortcuts.xcstrings \
  --stringsdata $(stringsdata Tonearm) $(stringsdata TonearmCore)
# shellcheck disable=SC2046
xcrun xcstringstool sync Sources/Discovery/Localization/Localizable.xcstrings \
  --stringsdata $(stringsdata TonearmDiscovery)
# shellcheck disable=SC2046
xcrun xcstringstool sync WatchApp/Localizable.xcstrings WatchApp/AppShortcuts.xcstrings \
  --stringsdata $(stringsdata TonearmWatch)
# shellcheck disable=SC2046
xcrun xcstringstool sync WidgetsExtension/Localizable.xcstrings --stringsdata $(stringsdata TonearmWidgetsExtension)
# shellcheck disable=SC2046
xcrun xcstringstool sync ShareExtension/Localizable.xcstrings --stringsdata $(stringsdata TonearmShareExtension)

echo "Catalogs synced. Stale keys are marked extractionState=stale; remove them once confirmed unused."
