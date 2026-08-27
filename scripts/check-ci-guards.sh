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
[ "$watch_ok" = "1" ] && echo "    OK"

if [ "$status" != "0" ]; then
  echo
  echo "one or more guards failed — this is what CI would have told you, sooner"
fi
exit $status
