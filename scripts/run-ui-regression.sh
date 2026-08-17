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
#   make test-ui-regression LANES=djmix     # the DJ live-mix journey (gates M5)
#   make test-ui-regression LANES=djlive    # the same, against real Jamendo
#   make test-ui-regression LANES=djhw      # M6: cue, MIDI, purchase row (no recording)
#
# Lanes whose prerequisites are absent SKIP with a stated reason and do not fail
# the run — a missing credential or an unreachable demo server is not a product
# defect (§53.4). Only an assertion about Platterhead's own behaviour can fail.
#
# THE DJ LANES (§53.7–53.12)
# XCUITest cannot hear, so these drive the real UI and then assert against the
# recording the app itself produced: this script pulls the export out of the
# simulator container and runs scripts/ui-regression/verify-mix.py against it.
#
# The recorded mix is KEPT, in build/ui-regression/dj/ — the analyzer's thresholds
# are a judgement call, and a human has to be able to play the file and decide
# whether they are tuned right before trusting a pass or chasing a fail. That
# directory is wiped at the START of every DJ run, and every intermediate is
# deleted at the end, so exactly one audio file is left and it is always this
# run's. KEEP_INTERMEDIATES=1 retains the journal and decoded audio for debugging.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

COMPOSE_FILE="docker-compose.ui-regression.yml"
CREDENTIALS_FILE=".test-credentials"
IOS_DESTINATION="${TONEARM_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=${TONEARM_IOS_SIMULATOR_NAME:-iPhone 16}}"
LANES="${LANES:-all}"

# ── DJ lane settings (§53.7–53.12) ───────────────────────────────────────────
# One stable directory, wiped at the start of every DJ run so a rerun never leaves
# you listening to last run's mix. Intermediates are deleted at the end; exactly
# one audio file survives, because the point of keeping it is that a human can
# play it and judge whether the thresholds are tuned right.
DJ_ARTIFACTS="build/ui-regression/dj"
DJ_MIX="$DJ_ARTIFACTS/dj-mix.m4a"
DJ_JOURNAL="$DJ_ARTIFACTS/mix-journal.json"
APP_BUNDLE_ID="${TONEARM_BUNDLE_ID:-guru.parso.tonearm}"
# Set KEEP_INTERMEDIATES=1 to retain the journal and any decoded WAV for debugging.
KEEP_INTERMEDIATES="${KEEP_INTERMEDIATES:-0}"
MIX_MINUTES="${MIX_MINUTES:-6}"
export MIX_MINUTES

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
  # The run log is deliberately NOT removed — see where it is opened below.
  rm -f "${RUN_MARKER:-}"
  # An interrupted run leaves the heartbeat ticker and its fifo behind.
  [[ -n "${TICKER_PID:-}" ]] && kill "$TICKER_PID" 2>/dev/null
  rm -f "${RUN_PIPE:-}"
  if [[ "${LOCAL_SERVERS}" == "1" ]]; then
    log "tearing down backing servers"
    docker compose -f "$COMPOSE_FILE" down --volumes >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${LOCAL_SERVERS}" == "1" ]]; then
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
  # The DJ lane's mock catalogue. Only the deterministic lane uses it; djlive
  # deliberately points at the real host. `/v3.0` is the Jamendo read API's
  # mount point, which `JamendoAppConfig.baseURL` is set against.
  export PH_TEST_JAMENDO_MOCK_URL="http://127.0.0.1:18092/v3.0"
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

# ── forwarding the environment into the test runner ──────────────────────────
#
# A UI test does NOT inherit this shell's environment. The test bundle runs
# inside its own runner process on the simulator, launched by testmanagerd, and
# `ProcessInfo.processInfo.environment` there sees nothing exported here — which
# is silent, because `RegressionEnv.require` turns a missing key into a §53.4
# skip, so the lanes stay "green" while asserting nothing.
#
# The supported channel is the `TEST_RUNNER_` prefix: xcodebuild forwards any
# variable so named into the runner process with the prefix stripped. So mirror
# every key the suite reads. Doing it by loop rather than by hand means a new
# `[section]` in .test-credentials is carried through automatically and cannot
# be forgotten (which is how this went unnoticed).
forward_to_test_runner() {
  local name value
  for name in $(compgen -v | grep -E '^PH_TEST_' || true); do
    value="${!name}"
    export "TEST_RUNNER_${name}=${value}"
  done
  export "TEST_RUNNER_MIX_MINUTES=${MIX_MINUTES}"
}
forward_to_test_runner

# ── run ──────────────────────────────────────────────────────────────────────

DJ_LANE=0
case "$LANES" in
  all)        FILTER=(-only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests
                      -only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests
                      -only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests) ;;
  nowplaying) FILTER=(-only-testing:TonearmUIRegressionTests/NowPlayingRegressionUITests) ;;
  playlists)  FILTER=(-only-testing:TonearmUIRegressionTests/PlaylistRegressionUITests) ;;
  remote)     FILTER=(-only-testing:TonearmUIRegressionTests/RemoteLibraryRegressionUITests) ;;
  djmix)      FILTER=(-only-testing:TonearmUIRegressionTests/DJMixRegressionUITests); DJ_LANE=1 ;;
  djlive)     FILTER=(-only-testing:TonearmUIRegressionTests/DJLiveMixRegressionUITests); DJ_LANE=1 ;;
  # The M6 feature lanes (plan 6.7): cue, MIDI and the purchase row, driven
  # through the real UI. They record nothing, so they are not a DJ_LANE — there
  # is no mix to pull or verify, and demanding one would fail every run.
  djhw)       FILTER=(-only-testing:TonearmUIRegressionTests/DJHardwareRegressionUITests) ;;
  # The stems lane (plan S8): separates a real track and proves the vocal
  # fader moves the recorded audio. It records, so it is a DJ_LANE — skipped
  # honestly when the ODR tag is absent, verified by the analyzer when present.
  djstem)     FILTER=(-only-testing:TonearmUIRegressionTests/DJStemRegressionUITests); DJ_LANE=1 ;;
  *)          echo "Usage: LANES=[all|nowplaying|playlists|remote|djmix|djlive|djhw|djstem] $0" >&2; exit 2 ;;
esac

# Wipe the DJ artifacts BEFORE the run, so a rerun can never leave you auditioning
# the previous run's mix and drawing conclusions from it.
if [[ "$DJ_LANE" == "1" ]]; then
  log "clearing previous DJ artifacts in $DJ_ARTIFACTS"
  rm -rf "$DJ_ARTIFACTS"
  mkdir -p "$DJ_ARTIFACTS"
  log "DJ lane: ${MIX_MINUTES}-minute mix (set MIX_MINUTES=20 for the pre-release soak)"
fi

# ── progress monitor ─────────────────────────────────────────────────────────
#
# `xcodebuild test` prints a wall of build output and then goes quiet for the
# length of a lane — fifteen to twenty minutes for `djmix`, during which the only
# way to tell a working run from a wedged one was to open the log in another
# window. The owner asked for high-level progress with timestamps instead.
#
# So: the full output still goes to $RUN_LOG, unabridged, and what reaches the
# terminal is phase lines, test-case boundaries, failures — and a heartbeat every
# HEARTBEAT_SECONDS that says how long the run has been going, which test is in
# flight, and the last thing the UI test actually did.
#
# The heartbeat arrives as a `__TICK__` line from a ticker process writing into
# the same fifo, rather than from `read -t`. **`read -t` cannot be used here:**
# macOS ships bash 3.2, where a timeout returns 1 — indistinguishable from EOF —
# so a loop written that way exits at the first quiet half-minute and takes the
# rest of the log with it. Verified, not assumed. (bash 4+ returns >128.)
HEARTBEAT_SECONDS=30

progress_monitor() {
  local start=$SECONDS line current="(building)" last_activity="" printed_testing=0

  elapsed() {
    local secs=$((SECONDS - start))
    printf '%dm%02ds' $((secs / 60)) $((secs % 60))
  }

  while IFS= read -r line; do
    if [[ "$line" == "__TICK__" ]]; then
      printf '    [%s] still running · %s%s\n' "$(elapsed)" "$current" \
        "${last_activity:+ · last: $last_activity}"
      continue
    fi

    printf '%s\n' "$line" >> "$RUN_LOG"

    case "$line" in
      "Test Suite '"*"' started"*)
        if [[ "$printed_testing" == "0" ]]; then
          printf '==> [%s] build finished, testing started\n' "$(elapsed)"
          printed_testing=1
        fi
        ;;
      "Test Case '"*"' started"*)
        current="$(printf '%s' "$line" | sed -E "s/.*-\[[^ ]+ ([A-Za-z0-9_]+)\].*/\1/")"
        last_activity=""
        printf '==> [%s] %s\n' "$(elapsed)" "$current"
        ;;
      "Test Case '"*"' passed"*)
        printf '    [%s] PASS %s (%s)\n' "$(elapsed)" "$current" \
          "$(printf '%s' "$line" | sed -E 's/.*\(([0-9.]+) seconds\).*/\1s/')"
        current="(between tests)"
        ;;
      "Test Case '"*"' failed"*)
        printf '    [%s] FAIL %s\n' "$(elapsed)" "$current"
        current="(between tests)"
        ;;
      *": error:"*|*"XCTAssertionFailure"*|*" failed - "*)
        printf '    [%s] %s\n' "$(elapsed)" "$line"
        ;;
      "** TEST "*|"** BUILD "*)
        printf '==> [%s] %s\n' "$(elapsed)" "$line"
        ;;
      *"    t = "*)
        # XCUITest's own activity trace: the live sense of where a lane is.
        # Not printed on arrival (there are thousands) — carried for the next
        # heartbeat, which is exactly the "what is it doing right now" the
        # silence used to hide.
        last_activity="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//' | cut -c1-90)"
        ;;
    esac
  done
  printf '==> [%s] run finished — full output in %s\n' "$(elapsed)" "$RUN_LOG"
}

log "running UI regression lanes '${LANES}' on ${IOS_DESTINATION}"
# A marker file stamped the moment the lanes started, so a stale export left in
# the simulator's container by an earlier run cannot be mistaken for this run's
# evidence. A file rather than an epoch: BSD `find` has no `-newermt @<epoch>`
# (it prints "Can't parse date/time" and matches nothing), and `-newer <file>`
# is the form both finds agree on.
RUN_MARKER="$(mktemp -t ui-regression-run)"
# The lanes' own output, kept so the artifact step can tell a lane that *ran*
# from one that skipped on an absent prerequisite (§53.4). Only the former owes
# this run a recording.
#
# **Kept on disk, not a mktemp deleted on exit.** It used to be the latter, and
# that is why AT-MIX-01's run-3 failure on 2026-08-16 has no recorded cause: by
# the time anyone wanted to read it, it had been unlinked by the trap. A lane
# takes fifteen to twenty minutes; throwing away the only record of it to save
# a few megabytes is a bad trade. It lives outside `$DJ_ARTIFACTS`, which is
# wiped at the start of every DJ run, and is timestamped so consecutive runs do
# not overwrite each other's evidence.
mkdir -p build/ui-regression/logs
RUN_LOG="build/ui-regression/logs/$(date +%Y%m%d-%H%M%S)-${LANES}.log"
log "run log: $RUN_LOG"
set +e
# **Keep the host awake for the whole run.** A `djmix` lane is fifteen to
# twenty minutes of an audio graph that has to keep rendering the entire time,
# and the simulator's audio is a proxy to the host's Core Audio: when the Mac
# sleeps, `HALS_IOEngine2::StopIO` stops IO on the device, the simulator's
# transport ends, and AVAudioEngine's render callback is never pulled again.
# The master clock stops, the record tap starves, and the app goes on showing a
# recording that is no longer being written. That is exactly how one run died —
# the lid closed at minute five and the suite spent the next fourteen minutes
# blaming the decks. `caffeinate -dims` holds off display and idle system sleep for
# the length of the build. It cannot defeat a clamshell close on battery, which
# is why `holdMix` also names a frozen master clock when it sees one.
#
# **Release, not the default Debug.** The DJ lanes are the only suite whose
# result depends on the app keeping a real-time deadline: 128 frames at 48 kHz
# is a 2.67 ms render budget, and unoptimised Swift DSP does not make it. The
# graph then renders as fast as the CPU allows — measured at a third of real
# time — so a "six-minute mix" took eighteen minutes of wall clock and every
# wall-clock assumption in the suite was wrong. Release is also what a
# pre-release gate should be exercising.
# The monitor reads from a fifo rather than a pipe so the ticker can write into
# the same stream (see progress_monitor). xcodebuild's status comes back
# directly, not out of PIPESTATUS, because it is no longer in a pipeline.
RUN_PIPE="$(mktemp -u -t ui-regression-pipe)"
mkfifo "$RUN_PIPE"
progress_monitor < "$RUN_PIPE" &
MONITOR_PID=$!
( while :; do sleep "$HEARTBEAT_SECONDS"; printf '__TICK__\n'; done ) > "$RUN_PIPE" &
TICKER_PID=$!

caffeinate -dims \
xcodebuild test \
  -project Tonearm.xcodeproj \
  -scheme TonearmUIRegression \
  -configuration Release \
  -destination "$IOS_DESTINATION" \
  "${FILTER[@]}" > "$RUN_PIPE" 2>&1
XCODEBUILD_STATUS=$?

# Closing the ticker closes the last writer, which is what ends the monitor.
kill "$TICKER_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
rm -f "$RUN_PIPE"
unset TICKER_PID RUN_PIPE
set -e

if [[ "$DJ_LANE" != "1" ]]; then
  exit $XCODEBUILD_STATUS
fi

# A DJ lane that skipped never recorded anything, and that is a legitimate
# outcome: `djlive` without a `client_id`, `djmix` without Docker (§53.4). Only
# a lane that actually executed owes this run an artifact.
if ! grep -qE "^Test Case .* (passed|failed) \(" "$RUN_LOG"; then
  log "every DJ lane skipped — see the reason each printed above. Nothing was recorded,"
  log "so there is nothing to verify; this is a skip, not a pass with no evidence."
  exit $XCODEBUILD_STATUS
fi

# ── DJ artifacts: pull, verify, keep exactly one audio file ──────────────────
#
# The share sheet is unautomatable, so under -uiRegression the app writes the
# export to its container instead (§53.11). Pull it out here.

# The iPhone the lanes just ran on. A watchOS simulator is usually booted too
# (the commit hook's watch smoke test leaves one), and asking it for the app's
# container fails with the misleading "no export directory" warning below — so
# pick an iOS device, preferring the one this run targeted.
#
# **Booted is preferred but not required.** `simctl get_app_container` refuses on
# a shut-down device ("Unable to lookup in current state: Shutdown"), and
# xcodebuild leaves the device shut down when it booted it itself — which is
# what happens whenever Simulator.app was not already open. So fall back to the
# named device and boot it, rather than reporting a green run with nothing
# verified.
target_udid() {
  xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, os, sys
wanted = os.environ.get("TONEARM_IOS_SIMULATOR_NAME", "iPhone 16")
devices = json.load(sys.stdin)["devices"]
ios = [d for runtime, entries in devices.items() if "iOS" in runtime
       for d in entries if d.get("isAvailable")]
booted = [d for d in ios if d.get("state") == "Booted"]
named = [d for d in ios if d.get("name") == wanted]
print(next((d["udid"] for d in booted if d.get("name") == wanted),
           booted[0]["udid"] if booted else
           (named[0]["udid"] if named else "")))' 2>/dev/null
}

# **A DJ run that cannot produce its evidence has failed.** Everything below is
# the actual assertion — the lanes only perform the mix; `verify-mix.py` is what
# proves it happened. Skipping past a missing export would report a green gate
# for a milestone nothing checked, which is the stale-export failure mode (§14)
# wearing a different hat. Prerequisites skip (§53.4); a missing artifact from
# lanes that ran does not.
dj_evidence_missing() {
  warn "$1"
  warn "the djmix lanes ran, so this is a failed run and not a skip: the recording is"
  warn "the only evidence the transitions happened (§53.8)."
  exit $((XCODEBUILD_STATUS == 0 ? 1 : XCODEBUILD_STATUS))
}

UDID="$(target_udid)"
if [[ -z "$UDID" ]]; then
  dj_evidence_missing "no iOS simulator to retrieve the recorded mix from."
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$APP_BUNDLE_ID" data 2>/dev/null || true)"
EXPORT_DIR="$CONTAINER/Documents/uiRegression/export"
if [[ -z "$CONTAINER" || ! -d "$EXPORT_DIR" ]]; then
  dj_evidence_missing "no export directory in the app container — the recording never finalised."
fi

# **Only an export this run produced.** The container outlives the run, so a
# lane that fails before finalize leaves the previous run's mix sitting there —
# and the analyzer, handed it, prints a verdict table full of PASSes about audio
# nobody just recorded. That is the one failure mode a suite must not have. The
# `-newer` filter is what makes a missing recording read as missing.
found_mix="$(find "$EXPORT_DIR" -type f \( -name '*.m4a' -o -name '*.caf' -o -name '*.wav' \) \
  -newer "$RUN_MARKER" | head -1)"
if [[ -z "$found_mix" ]]; then
  if find "$EXPORT_DIR" -type f -name '*.m4a' | grep -q .; then
    warn "the only mix in $EXPORT_DIR predates this run — the lanes never finalised a"
    warn "recording, so there is nothing from this run to verify. Not verifying the old one."
  else
    warn "no recorded mix in $EXPORT_DIR — nothing to verify."
  fi
  exit $((XCODEBUILD_STATUS == 0 ? 1 : XCODEBUILD_STATUS))
fi

DJ_MIX="$DJ_ARTIFACTS/dj-mix.${found_mix##*.}"
cp "$found_mix" "$DJ_MIX"
[[ -f "$EXPORT_DIR/mix-journal.json" ]] && cp "$EXPORT_DIR/mix-journal.json" "$DJ_JOURNAL"

# The fixture manifest is the analyzer's source of the per-deck tone identities
# (§5, §53.8) — the app does not know them and must not hardcode them. It lives
# inside the mock container's media volume; copy it to the host for the run.
#
# **Only for the deterministic lane.** The manifest is the tone-identity table,
# and tone identity is a property of the *fixtures*. The live lane mixes real
# music, which has broadband low end on both decks and no tone identities at
# all (§8.2, §53.12) — and performs no scripted transitions to look for. Handing
# the analyzer a manifest there asks it to verify five signatures of a mix that
# was never asked to contain them, and it dutifully fails all five.
DJ_MANIFEST="$DJ_ARTIFACTS/dj-fixture-manifest.json"
if [[ "${LOCAL_SERVERS}" == "1" && "$LANES" == "djmix" ]]; then
  docker compose -f "$COMPOSE_FILE" cp jamendo-mock:/media/dj-fixture-manifest.json \
    "$DJ_MANIFEST" >/dev/null 2>&1 || true
fi
# Without the manifest the analyzer has no tone identities, and it treats that as
# the live lane and asserts nothing. On the gating lane that is not a skip.
if [[ "$LANES" == "djmix" && ! -f "$DJ_MANIFEST" ]]; then
  dj_evidence_missing "the fixture manifest could not be pulled from the mock — the tone
    signatures the gating lane exists to assert would be silently skipped."
fi

log "verifying the recorded mix against its journal"
VERIFY_STATUS=0
if [[ -f "$DJ_JOURNAL" ]]; then
  VERIFY_ARGS=()
  [[ -f "$DJ_MANIFEST" ]] && VERIFY_ARGS=(--fixture-manifest "$DJ_MANIFEST")
  python3 scripts/ui-regression/verify-mix.py "$DJ_MIX" "$DJ_JOURNAL" "${VERIFY_ARGS[@]}" || VERIFY_STATUS=$?
else
  # The journal is written at finalize under -uiRegression, so its absence means
  # the cross-check (§53.9) did not happen — never a pass.
  warn "no mix-journal.json beside the export — signatures cannot be cross-checked (§53.9)."
  VERIFY_STATUS=1
fi

# Intermediates go; the audio stays. Keeping the mix is the point: the analyzer's
# thresholds are a judgement call, and a human has to be able to play the file and
# decide whether they are tuned right before trusting a pass or chasing a fail.
if [[ "$KEEP_INTERMEDIATES" != "1" ]]; then
  find "$DJ_ARTIFACTS" -type f ! -path "$DJ_MIX" -delete 2>/dev/null || true
else
  log "KEEP_INTERMEDIATES=1 — journal and decoded audio retained in $DJ_ARTIFACTS"
fi

log "listen to the mix this run produced:"
log "    open \"$DJ_MIX\""

if [[ $XCODEBUILD_STATUS -ne 0 ]]; then exit $XCODEBUILD_STATUS; fi
exit $VERIFY_STATUS
