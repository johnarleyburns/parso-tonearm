#!/usr/bin/env bash
# Fetches the Mood Starter databases (StarterLibrary) pinned in Config/starter.lock into
# Resources/Audio/. They are build inputs, not source: the Mac one carries every track's full
# transition-prep waveform (~100 MB), and committing binary rebuilds would bloat history and run
# into GitHub's 100 MB file limit — the same reason Core ML models are fetched (fetch-models.sh).
#
# A file already present with the pinned checksum is kept; a mismatch is replaced, a failed
# download or checksum is a hard failure (a build without its starter DB would ship an empty
# Mood Starter library, so Build a Mix would have nothing to mix on a fresh install).
#
# Usage: scripts/fetch-starter.sh [--force]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

LOCK="Config/starter.lock"
DEST="Resources/Audio"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ ! -f "$LOCK" ]]; then
  echo "starter: no $LOCK — nothing to fetch" >&2
  exit 1
fi
mkdir -p "$DEST"
fetched=0
kept=0

while read -r url sha file; do
  [[ -z "${url:-}" || "${url:0:1}" == "#" ]] && continue
  target="$DEST/$file"
  if [[ -f "$target" && "$FORCE" == "0" ]]; then
    if [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$sha" ]]; then
      echo "==> starter: $file present and verified — kept"
      kept=$((kept + 1))
      continue
    fi
    echo "==> starter: $file differs from the pinned build — replacing"
  fi
  tmp="$(mktemp -t starter-db)"
  echo "==> starter: fetching $file"
  if ! curl -fSL --retry 3 --retry-delay 5 -o "$tmp" "$url" < /dev/null; then
    rm -f "$tmp"
    echo "starter: could not download $url — the release asset in $LOCK has to exist and be public." >&2
    exit 1
  fi
  actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    echo "starter: checksum mismatch for $file (expected $sha, got $actual)" >&2
    exit 1
  fi
  mv "$tmp" "$target"
  echo "==> starter: $file verified"
  fetched=$((fetched + 1))
done < "$LOCK"

echo "==> starter: $fetched fetched, $kept already present"
