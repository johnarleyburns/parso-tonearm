#!/bin/bash
# Platterhead UI regression runner. This suite is intentionally manual-only:
# it needs Docker, a simulator, and the demo services used by the UI tests.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

LANES="${LANES:-all}"
COMPOSE_FILE="docker-compose.ui-regression.yml"
IOS_SIMULATOR_NAME="${TONEARM_IOS_SIMULATOR_NAME:-iPhone 17}"
if [[ -z "${TONEARM_IOS_TEST_DESTINATION:-}" ]] &&
   ! xcrun simctl list devices available | grep -Fq " ${IOS_SIMULATOR_NAME} ("; then
  IOS_SIMULATOR_NAME="$(xcrun simctl list devices available |
    sed -nE 's/^[[:space:]]+(iPhone[^ (]*( [^ (]+)*) \([A-F0-9-]+\).*/\1/p' | head -1)"
fi
IOS_DESTINATION="${TONEARM_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=${IOS_SIMULATOR_NAME}}"
CREDENTIALS_FILE=".test-credentials"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'SKIP: %s\n' "$*" >&2; }

if [[ -f "$CREDENTIALS_FILE" ]]; then
  log "loading test credentials (values never logged)"
  eval "$({
    awk -F= '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section); gsub(/[.-]/, "_", section); next }
      NF >= 2 { key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key); value = substr($0, index($0, "=") + 1); sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); if (value == "") next; gsub(/[.-]/, "_", key); gsub(/\047/, "\047\\\\\047\047", value); printf "export PH_TEST_%s_%s=%s\n", toupper(section), toupper(key), "\047" value "\047" }
    ' "$CREDENTIALS_FILE"
  })"
else
  warn "$CREDENTIALS_FILE not found; credentialed lanes may skip."
fi

LOCAL_SERVERS=0
if docker info >/dev/null 2>&1; then
  LOCAL_SERVERS=1
  log "starting local regression services"
  docker compose -f "$COMPOSE_FILE" up -d --wait || warn "some local services are unavailable"
  export PH_TEST_WEBDAV_URL="http://127.0.0.1:18091"
  export PH_TEST_WEBDAV_USERNAME="platterhead"
  export PH_TEST_WEBDAV_PASSWORD="regression"
  export PH_TEST_SMB_HOST="127.0.0.1"
  export PH_TEST_SMB_PORT="18445"
  export PH_TEST_SMB_SHARE="Music"
  export PH_TEST_SMB_USERNAME="platterhead"
  export PH_TEST_SMB_PASSWORD="regression"
fi
trap 'if [[ "$LOCAL_SERVERS" == "1" ]]; then docker compose -f "$COMPOSE_FILE" down --volumes >/dev/null 2>&1 || true; fi' EXIT

export PH_TEST_SUBSONIC_DEMO_URL="https://demo.navidrome.org"
export PH_TEST_SUBSONIC_DEMO_USERNAME="demo"
export PH_TEST_SUBSONIC_DEMO_PASSWORD="demo"
export PH_TEST_JELLYFIN_DEMO_URL="https://demo.jellyfin.org/stable"
export PH_TEST_JELLYFIN_DEMO_USERNAME="demo"
export PH_TEST_JELLYFIN_DEMO_PASSWORD=""
export PH_TEST_ARCHIVE_PUBLIC_COLLECTION="The Vapor Vault"

forward_to_test_runner() {
  local name value
  for name in $(compgen -v | grep -E '^PH_TEST_' || true); do
    value="${!name}"
    export "TEST_RUNNER_${name}=${value}"
  done
}
forward_to_test_runner

case "$LANES" in
  all) FILTER=(
    -only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests
    -only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests
    -only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests
    -only-testing:TonearmUIRegressionTests/SettingsRegressionUITests) ;;
  nowplaying) FILTER=(-only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests) ;;
  playlists) FILTER=(-only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests) ;;
  remote) FILTER=(-only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests) ;;
  settings) FILTER=(-only-testing:TonearmUIRegressionTests/SettingsRegressionUITests) ;;
  *) echo "Usage: LANES=[all|nowplaying|playlists|remote|settings] $0" >&2; exit 2 ;;
esac

log "running UI regression lane '$LANES' on $IOS_DESTINATION"
xcodebuild test \
  -project Tonearm.xcodeproj \
  -scheme TonearmUIRegression \
  -configuration Release \
  -destination "$IOS_DESTINATION" \
  "${FILTER[@]}"
