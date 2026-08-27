#!/bin/bash
# The repository's structural guards — `make ci-guards`, and the step CI runs.
#
# WHY THIS IS A SCRIPT AND NOT INLINE YAML. These three checks lived as inline
# `run:` blocks in .github/workflows/ios.yml, which means they could only ever
# run on a push. The first push of the DJ work (2026-08-17) died on one of them
# — the StoreKit grep, on a false positive it had been carrying for months —
# after a full test job, when the same check takes under a second on a laptop.
# A guard nobody can run before pushing is a guard that fails at the most
# expensive possible moment.
#
# Each check exits non-zero with the offending files named. Run it any time;
# it reads the tree and writes nothing.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0

# ── Swift 6 contract ────────────────────────────────────────────────────────
echo "==> Swift 6 contract"
if bash scripts/check-swift6.sh; then
  echo "    OK"
else
  status=1
fi

# ── StoreKit import boundary (Ground rule #2) ───────────────────────────────
#
# `import StoreKit` is permitted ONLY under Sources/Pro/ and the paywall view.
# Any other occurrence leaks the StoreKit dependency past the Pro boundary.
#
# **Match the import statement, not the phrase.** The bare-substring form failed
# on Sources/DJ/Features/Paywall/PaywallModel.swift, whose doc comment says the
# model "cannot import StoreKit" — the rule being enforced, written down. A
# guard that fails on a file explaining that it obeys the guard teaches people
# to route around it.
echo "==> StoreKit import boundary"
LEAKS=$(grep -rlnE "^[[:space:]]*import StoreKit([[:space:]]|$)" Sources WatchApp \
  | grep -v "^Sources/Pro/" \
  | grep -v "^Sources/Features/Settings/ProPaywallView.swift" \
  || true)
if [ -n "$LEAKS" ]; then
  echo "    StoreKit import leaked outside Sources/Pro/ and the paywall:"
  echo "$LEAKS" | sed 's/^/      /'
  status=1
else
  echo "    OK"
fi

# ── Codename leak (Platterhead is the product name; Tonearm is internal) ────
echo "==> Codename leak"
codename_ok=1

# (a) project.yml CFBundleDisplayName must be Platterhead (suffixed variants allowed)
DISPLAY_NAMES=$(grep 'CFBundleDisplayName:' project.yml | sed 's/.*CFBundleDisplayName: *//' || true)
while IFS= read -r name; do
  if [ -n "$name" ] && [[ "$name" != *Platterhead* ]]; then
    echo "    CFBundleDisplayName does not contain Platterhead: '$name'"
    status=1; codename_ok=0
  fi
done <<< "$DISPLAY_NAMES"

# (b) No user-visible "Tonearm" in Swift string literals or Info.plist string
# values. Grep only for "Tonearm" inside double-quoted strings (catches
# user-facing copy), then exclude the internal quoted-string uses:
#   "tonearm" (URL scheme), "TonearmShareExtension" (NSError domain),
#   "TonearmOAuthClientIDs"/"TonearmOAuthClientSecrets" (plist keys),
#   "Tonearm/StreamCache" etc. (on-disk dirs), PROVISIONING_PROFILE_SPECIFIER.
UI_DIRS=(Sources/Features Sources/App Sources/Widgets Sources/Intents
         Sources/DesignSystem WidgetsExtension ShareExtension WatchApp)

for dir in "${UI_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  LEAK=$(grep -rIE '"[^"]*Tonearm[^"]*"' "$dir" \
    | grep -v '"tonearm"' \
    | grep -v '"TonearmOAuthClientIDs' \
    | grep -v '"TonearmOAuthClientSecrets' \
    | grep -v '"TonearmShareExtension"' \
    | grep -v 'appendingPathComponent("Tonearm' \
    | grep -v 'PROVISIONING_PROFILE_SPECIFIER' \
    || true)
  if [ -n "$LEAK" ]; then
    echo "    Codename leak found in $dir:"
    echo "$LEAK" | sed 's/^/      /'
    status=1; codename_ok=0
  fi
done
[ "$codename_ok" = "1" ] && echo "    OK"

# ── Watch architecture boundary ────────────────────────────────────────────
echo "==> Watch architecture boundary"
watch_ok=1
WATCH_TARGET=$(sed -n '/^  TonearmWatch:/,/^  WatchUITests:/p' project.yml)
for product in TonearmWatchProtocol TonearmWatchCore TonearmWatchLegacyCore; do
  if ! printf '%s\n' "$WATCH_TARGET" | grep -q "product: $product"; then
    echo "    TonearmWatch is missing scoped product $product"
    status=1; watch_ok=0
  fi
done
if printf '%s\n' "$WATCH_TARGET" | awk '
  /- package: TonearmCore/ { pending = 1; next }
  pending && /product: TonearmWatch(Protocol|Core|LegacyCore)/ { pending = 0; next }
  pending && /product:/ { exit 1 }
  END { exit pending ? 1 : 0 }
'; then :; else
  echo "    TonearmWatch links broad TonearmCore"
  status=1; watch_ok=0
fi

WATCH_CLOUD_LEAKS=$(grep -rlnE '^[[:space:]]*import[[:space:]]+CloudKit([[:space:]]|$)|CKContainer|iCloud\.com|OAuthToken|CredentialStore' WatchApp Sources/WatchProtocol Sources/WatchCore Sources/WatchLegacy 2>/dev/null || true)
if [ -n "$WATCH_CLOUD_LEAKS" ]; then
  echo "    CloudKit/credential code leaked into the watch closure:"
  echo "$WATCH_CLOUD_LEAKS" | sed 's/^/      /'
  status=1; watch_ok=0
fi

NONLEGACY_GRDB=$(grep -rlnE '^[[:space:]]*import[[:space:]]+GRDB([[:space:]]|$)' WatchApp Sources/WatchProtocol Sources/WatchCore 2>/dev/null || true)
if [ -n "$NONLEGACY_GRDB" ]; then
  echo "    GRDB is allowed only in TonearmWatchLegacyCore:"
  echo "$NONLEGACY_GRDB" | sed 's/^/      /'
  status=1; watch_ok=0
fi

if printf '%s\n' "$WATCH_TARGET" | grep -q 'CODE_SIGN_ENTITLEMENTS'; then
  echo "    TonearmWatch declares an entitlement file"
  status=1; watch_ok=0
fi
if ! grep -q 'cloudKitDatabase: \.none' Sources/WatchCore/Bootstrap/WatchStoreBootstrap.swift; then
  echo "    SwiftData watch store lacks explicit CloudKit opt-out"
  status=1; watch_ok=0
fi
for model in WatchTrackModel WatchPlaylistModel WatchPlaylistEntryModel WatchAssetModel WatchDownloadJobModel WatchDownloadRootModel WatchPlaybackStateModel WatchSyncStateModel; do
  if ! grep -q "class $model" Sources/WatchCore/Library/WatchLibraryModels.swift; then
    echo "    versioned Watch schema is missing $model"
    status=1; watch_ok=0
  fi
done
for stable_id in trackID playlistID entryID requestID rootID stateID; do
  if ! grep -q "@Attribute(\.unique) public var $stable_id" Sources/WatchCore/Library/WatchLibraryModels.swift; then
    echo "    Watch schema lacks unique stable ID: $stable_id"
    status=1; watch_ok=0
  fi
done
if ! grep -q 'enum WatchSchemaV1: VersionedSchema' Sources/WatchCore/Bootstrap/WatchStoreBootstrap.swift ||
   ! grep -q 'migrationPlan: WatchSchemaMigrationPlan.self' Sources/WatchCore/Bootstrap/WatchStoreBootstrap.swift; then
  echo "    Watch store must open through a versioned schema and migration plan"
  status=1; watch_ok=0
fi
if grep -q 'fatalError(' Sources/WatchCore/Bootstrap/WatchStoreBootstrap.swift; then
  echo "    Watch store bootstrap must never fatalError on an unreadable store"
  status=1; watch_ok=0
fi
# The launch scan must not invent checksums; only reconciliation hashes files.
if grep -rq 'pending-validation' Sources/WatchCore; then
  echo "    Watch recovery must not fabricate a checksum"
  status=1; watch_ok=0
fi
# Phase 2 keeps the new architecture off by default; Phase 6 flips it.
if ! grep -q 'ProcessInfo.processInfo.arguments.contains("-swiftDataWatchArchitecture")' WatchApp/App/WatchFeatureFlags.swift; then
  echo "    swiftDataWatchArchitecture must stay opt-in until the Phase 6 cutover"
  status=1; watch_ok=0
fi
[ "$watch_ok" = "1" ] && echo "    OK"

# ── Watch protocol boundary (Phase 3) ──────────────────────────────────────
#
# The Phase 3 definition of done: "no dynamic dictionary parsing exists outside
# adapters". That is only enforceable if a grep can find the exceptions, so the
# allowed list is here rather than in a comment somewhere.
echo "==> Watch protocol boundary"
protocol_ok=1

# (a) `[String: Any]` is confined to the envelope's dictionary bridge and the two
# WCSession adapters. Comment lines are stripped first: WatchTransport.swift's
# doc comment *states this rule*, and a guard that fails on the file explaining
# the guard is the StoreKit mistake above, repeated.
DICT_ALLOWED="Sources/WatchProtocol/Envelope.swift
Sources/WatchProtocol/Connectivity/WatchSessionTransport.swift
WatchApp/Connectivity/WatchProtocolSessionAdapter.swift
Sources/App/Watch/PhoneWatchProtocolAdapter.swift"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  printf '%s\n' "$DICT_ALLOWED" | grep -qxF "$file" && continue
  if sed 's|//.*||' "$file" | grep -q '\[String: Any\]'; then
    echo "    dynamic dictionary parsing outside an adapter: $file"
    status=1; protocol_ok=0
  fi
done <<< "$(find Sources/WatchProtocol Sources/WatchCore WatchApp/Connectivity Sources/App/Watch -name '*.swift' 2>/dev/null)"

# (b) A-06: a fault carries a code, never free text. A `String` *stored* property
# on WatchProtocolFault is one refactor away from a title or a path on the wire.
# Computed ones are fine and are how the copy is derived — `safeDisplayMessage`
# reads a fixed table keyed by the code — so only declarations that end the line
# (or carry a literal default) count.
if sed -n '/public struct WatchProtocolFault/,/^}/p' Sources/WatchProtocol/Errors.swift \
   | grep -qE '^[[:space:]]*public var [a-zA-Z]+: String\??([[:space:]]*=[^{]*)?[[:space:]]*$'; then
  echo "    WatchProtocolFault gained a free-text field (A-06 forbids it)"
  status=1; protocol_ok=0
fi

# (c) The adapters move bytes. A message kind named in one means protocol logic
# has started leaking below the transport seam.
for adapter in WatchApp/Connectivity/WatchProtocolSessionAdapter.swift Sources/App/Watch/PhoneWatchProtocolAdapter.swift; do
  [ -f "$adapter" ] || continue
  if sed 's|//.*||' "$adapter" | grep -q 'WatchMessageKind'; then
    echo "    transport adapter interprets message kinds: $adapter"
    status=1; protocol_ok=0
  fi
done

# (d) Both apps must speak the same version constant, not two copies of a number.
if ! grep -q 'public static let currentProtocolVersion' Sources/WatchProtocol/Envelope.swift; then
  echo "    WatchProtocolEnvelope has no single version constant"
  status=1; protocol_ok=0
fi
[ "$protocol_ok" = "1" ] && echo "    OK"

if [ "$status" != "0" ]; then
  echo
  echo "one or more guards failed — this is what CI would have told you, sooner"
fi
exit $status
