#!/bin/bash
# Fetch the converted Core ML model packages named in Config/models.lock —
# `make models`, and the step the CI archive job runs before `make project`.
#
# WHY THIS EXISTS. The CLAP encoders were committed to the repository until
# 2026-08-17, when the first `git push` of the DJ work was rejected outright:
#
#   remote: error: File Resources/Models/CLAPTextEncoder.mlpackage/.../weight.bin
#           is 239.13 MB; this exceeds GitHub's file size limit of 100.00 MB
#   ! [remote rejected] main -> main (pre-receive hook declined)
#
# So the packages are release assets now, pinned by tag and sha256, and this
# script puts them where the build expects them. Same treatment the 210 MB
# Demucs package already had by being gitignored — the difference is that these
# are fetched rather than merely absent, so a CI build still ships semantic
# search.
#
# A package already on this machine is left alone: the owner converts models
# locally with tools/clap-coreml/ and tools/demucs-coreml/, and re-downloading
# 370 MB over their conversion would be both slow and wrong. Pass --force to
# replace what is there with the pinned asset.
#
# Failure is always hard. An absent or corrupt model is not a warning: it would
# build cleanly and ship as the honest-unavailable state, and the first anyone
# would hear of it is a tester saying semantic search does nothing — which is
# exactly how the empty Jamendo key nearly shipped (alpha phase 1).

set -euo pipefail

cd "${TONEARM_REPO_ROOT:-$(git rev-parse --show-toplevel)}"

# A caller that needs only one model (for example, the audio-only starter
# shard builder) can supply a derived, checksum-pinned subset.  The default
# remains the complete production lock for normal app archives.
LOCK="${MODELS_LOCK:-Config/models.lock}"
DEST_ROOT="Resources/Models"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Where the bytes live is a hosting decision, so each row carries its own URL.
# MODELS_BASE_URL overrides the host and prefix for every row, keeping the
# filename — for a mirror, a fork, or moving buckets without touching the lock.
BASE="${MODELS_BASE_URL:-}"

if [[ ! -f "$LOCK" ]]; then
  echo "==> models: no $LOCK — nothing to fetch" >&2
  exit 1
fi

# Unpack a verified archive into a staging directory, check it holds exactly one
# expected top-level directory and no path traversal, and only then replace the
# destination. A rejected archive leaves any existing destination untouched.
unpack_model_asset() {
  local asset=$1 tmp=$2 destination=$3 archive_root=$4 stage listing
  case "$asset" in
    *.tar.gz) listing=$(tar -tzf "$tmp") || { echo "models: unreadable archive: $asset" >&2; return 1; } ;;
    *.zip) listing=$(unzip -Z1 "$tmp") || { echo "models: unreadable archive: $asset" >&2; return 1; } ;;
    *) echo "models: unsupported archive format: $asset" >&2; return 1 ;;
  esac
  if printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "models: archive path traversal rejected: $asset" >&2
    return 1
  fi
  stage=$(mktemp -d /tmp/tonearm-model.XXXXXX)
  case "$asset" in
    *.tar.gz) tar -xzf "$tmp" -C "$stage" ;;
    *.zip) unzip -q "$tmp" -d "$stage" ;;
  esac
  test -d "$stage/$archive_root" ||
    { echo "models: expected root missing: $archive_root" >&2; rm -rf "$stage"; return 1; }
  test "$(find "$stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ||
    { echo "models: archive has unexpected top-level content" >&2; rm -rf "$stage"; return 1; }
  rm -rf "$destination"
  mv "$stage/$archive_root" "$destination"
  rm -rf "$stage"
}

mkdir -p "$DEST_ROOT"
fetched=0
kept=0

while read -r url sha dir root || [[ -n "${url:-}" ]]; do
  # Skip blank lines and comments.
  [[ -z "${url:-}" || "${url:0:1}" == "#" ]] && continue

  target="$DEST_ROOT/$dir"
  # Rows with an archive root are the pinned CLAP pair: the directory is only
  # kept when it was installed from this exact archive (marker), so a model from
  # an earlier lock is replaced rather than kept.
  marker="$DEST_ROOT/.$dir.sha256"
  if [[ -n "${root:-}" && -d "$target" && "$(cat "$marker" 2>/dev/null)" != "$sha" ]]; then
    echo "==> models: $dir is not the pinned asset — replacing"
  elif [[ -d "$target" && "$FORCE" == "0" ]]; then
    echo "==> models: $dir already present — kept (--force to replace)"
    kept=$((kept + 1))
    continue
  fi

  asset="${url##*/}"
  [[ -n "$BASE" ]] && url="${BASE%/}/$asset"
  tmp="$(mktemp -t model-asset)"
  echo "==> models: fetching $asset"
  # `< /dev/null`: the loop is reading the lock file on stdin, and a child that
  # touches stdin would eat the remaining rows.
  if ! curl -fSL --retry 3 --retry-delay 5 -o "$tmp" "$url" < /dev/null; then
    rm -f "$tmp"
    echo "models: could not download $url" >&2
    echo "models: the release asset named in $LOCK has to exist and be public." >&2
    exit 1
  fi

  actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    echo "models: checksum mismatch for $asset" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    echo "models: the asset was replaced in place, or the download is corrupt." >&2
    exit 1
  fi

  if ! unpack_model_asset "$asset" "$tmp" "$target" "${root:-$dir}"; then
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  [[ -n "${root:-}" ]] && printf '%s\n' "$sha" > "$marker"
  echo "==> models: $dir unpacked and verified"
  fetched=$((fetched + 1))
done < "$LOCK"

echo "==> models: $fetched fetched, $kept already present"
