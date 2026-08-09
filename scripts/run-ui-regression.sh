#!/bin/bash
# Platterhead — UI regression suite runner (spec §53).
#
# The suite lives in its own target (TonearmUIRegressionTests) and its own scheme
# (TonearmUIRegression), so `xcodebuild test -scheme Tonearm` — the smoke path —
# cannot run it by accident. That separation is the "never in CI" rule made
# structural rather than conventional (§53.2).
#
# Run periodically, BY HAND, before a release. Deliberately not in CI, not in
# `make test-swift`, and not in any git hook: it needs Docker, a simulator, and
# the public internet, and it is allowed to take minutes (§53.2).
#
#   make test-ui-regression                 # every lane
#   make test-ui-regression LANES=remote    # one group
#
# Lanes whose prerequisites are absent SKIP with a stated reason and do not fail
# the run — a missing credential or an unreachable demo server is not a product
# defect (§53.4). Only an assertion about Platterhead's own behaviour can fail.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

COMPOSE_FILE="docker-compose.ui-regression.yml"
CREDENTIALS_FILE=".test-credentials"
IOS_DESTINATION="${TONEARM_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=${TONEARM_IOS_SIMULATOR_NAME:-iPhone 16}}"
LANES="${LANES:-all}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'SKIP: %s\n' "$*" >&2; }

# ── preflight ────────────────────────────────────────────────────────────────

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  warn "$CREDENTIALS_FILE not found — copy .test-credentials.example and fill it in."
  warn "Lanes needing credentials will skip; public lanes still run."
fi

if ! docker info >/dev/null 2>&1; then
  warn "Docker is not running — local-server lanes (WebDAV, SMB, Plex) will skip."
  LOCAL_SERVERS=0
else
  LOCAL_SERVERS=1
fi

# The suite reads credentials through the environment, never from a literal in a
# test file. Keys arrive as PH_TEST_<SECTION>_<KEY>, uppercased, dots and dashes
# to underscores (§54.2).
if [[ -f "$CREDENTIALS_FILE" ]]; then
  log "loading credentials from $CREDENTIALS_FILE (values never logged)"
  # shellcheck disable=SC2046
  eval $(
    awk -F= '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*\[/ {
        section = $0
        gsub(/[][[:space:]]/, "", section)
        gsub(/[.-]/, "_", section)
        next
      }
      NF >= 2 {
        key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
        value = substr($0, index($0, "=") + 1)
        sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
        if (value == "") next
        gsub(/[.-]/, "_", key)
        gsub(/\047/, "\047\\\\\047\047", value)   # survive a quote inside a value
        printf "export PH_TEST_%s_%s=%s\n", toupper(section), toupper(key), "\047" value "\047"
      }
    ' "$CREDENTIALS_FILE"
  )
fi

# ── backing servers ──────────────────────────────────────────────────────────

cleanup() {
  if [[ "${LOCAL_SERVERS}" == "1" ]]; then
    log "tearing down backing servers"
    docker compose -f "$COMPOSE_FILE" down --volumes >/dev/null 2>&1 || true
  fi
}

if [[ "${LOCAL_SERVERS}" == "1" ]]; then
  trap cleanup EXIT
  log "starting backing servers (fixture media, WebDAV, SMB, Plex)"
  PLEX_CLAIM="${PH_TEST_PLEX_CLAIM_TOKEN:-}" \
    docker compose -f "$COMPOSE_FILE" up -d --wait || {
      warn "one or more backing servers failed to become healthy; their lanes will skip"
    }
  export PH_TEST_WEBDAV_URL="http://127.0.0.1:18091"
  export PH_TEST_WEBDAV_USERNAME="platterhead"
  export PH_TEST_WEBDAV_PASSWORD="regression"
  export PH_TEST_SMB_HOST="127.0.0.1"
  export PH_TEST_SMB_PORT="18445"
  export PH_TEST_SMB_SHARE="Music"
  export PH_TEST_SMB_USERNAME="platterhead"
  export PH_TEST_SMB_PASSWORD="regression"
fi

# Public fixtures. These are published demo services with published credentials;
# they are safe to inline and are NOT secrets (§54.2).
export PH_TEST_SUBSONIC_DEMO_URL="https://demo.navidrome.org"
export PH_TEST_SUBSONIC_DEMO_USERNAME="demo"
export PH_TEST_SUBSONIC_DEMO_PASSWORD="demo"
export PH_TEST_JELLYFIN_DEMO_URL="https://demo.jellyfin.org/stable"
export PH_TEST_JELLYFIN_DEMO_USERNAME="demo"
export PH_TEST_JELLYFIN_DEMO_PASSWORD=""
export PH_TEST_ARCHIVE_PUBLIC_COLLECTION="The Vapor Vault"

# ── run ──────────────────────────────────────────────────────────────────────

case "$LANES" in
  all)        FILTER=(-only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests
                      -only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests
                      -only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests) ;;
  nowplaying) FILTER=(-only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests) ;;
  playlists)  FILTER=(-only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests) ;;
  remote)     FILTER=(-only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests) ;;
  *)          echo "Usage: LANES=[all|nowplaying|playlists|remote] $0" >&2; exit 2 ;;
esac

log "running UI regression lanes '${LANES}' on ${IOS_DESTINATION}"
xcodebuild test \
  -project Tonearm.xcodeproj \
  -scheme TonearmUIRegression \
  -destination "$IOS_DESTINATION" \
  "${FILTER[@]}"
