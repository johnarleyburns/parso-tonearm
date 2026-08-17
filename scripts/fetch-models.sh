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

cd "$(git rev-parse --show-toplevel)"

LOCK="Config/models.lock"
DEST_ROOT="Resources/Models"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Which repository's releases to resolve against. GITHUB_REPOSITORY is set by
# Actions; otherwise read it off the origin remote so a fork fetches its own.
if [[ -n "${MODELS_REPO:-}" ]]; then
  REPO="$MODELS_REPO"
elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  REPO="$GITHUB_REPOSITORY"
else
  REPO="$(git remote get-url origin \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
fi

if [[ ! -f "$LOCK" ]]; then
  echo "==> models: no $LOCK — nothing to fetch" >&2
  exit 1
fi

mkdir -p "$DEST_ROOT"
fetched=0
kept=0

while read -r tag asset sha dir; do
  # Skip blank lines and comments.
  [[ -z "${tag:-}" || "${tag:0:1}" == "#" ]] && continue

  target="$DEST_ROOT/$dir"
  if [[ -d "$target" && "$FORCE" == "0" ]]; then
    echo "==> models: $dir already present — kept (--force to replace)"
    kept=$((kept + 1))
    continue
  fi

  url="https://github.com/$REPO/releases/download/$tag/$asset"
  tmp="$(mktemp -t model-asset)"
  echo "==> models: fetching $asset from $tag"
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

  rm -rf "$target"
  tar -xzf "$tmp" -C "$DEST_ROOT"
  rm -f "$tmp"

  if [[ ! -d "$target" ]]; then
    echo "models: $asset did not contain $dir" >&2
    exit 1
  fi
  echo "==> models: $dir unpacked and verified"
  fetched=$((fetched + 1))
done < "$LOCK"

echo "==> models: $fetched fetched, $kept already present"
