#!/usr/bin/env bash
# Build one immutable Starter Blend AAC release. Run only in GitHub Actions:
# TONEARM_JAMENDO_CLIENT_ID is an Actions secret and must never be logged.
set -euo pipefail

tag="${1:?usage: publish-starter-blend-aac.sh <new-release-tag> [output-directory]}"
out="${2:-dist/starter-blends-$tag}"
catalog="Config/starter-blend-source.json"
: "${TONEARM_JAMENDO_CLIENT_ID:?TONEARM_JAMENDO_CLIENT_ID is required}"
command -v curl >/dev/null
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null
command -v jq >/dev/null
command -v shasum >/dev/null

[[ "$tag" =~ ^starter-blends-aac-v[0-9]+$ ]] || { echo "invalid release tag: $tag" >&2; exit 2; }
[[ -f "$catalog" ]] || { echo "missing $catalog" >&2; exit 2; }
[[ ! -e "$out" ]] || { echo "refusing to overwrite $out" >&2; exit 2; }
jq -e '.licenseReview.status == "owner-verified" and .licenseReview.license == "CC0"' "$catalog" >/dev/null \
  || { echo "owner CC0 review is not recorded in $catalog" >&2; exit 2; }
mkdir -p "$out/audio" "$out/source"

ids="$(jq -r '[.blends[].tracks[]] | unique | join("+")' "$catalog")"
api="$(mktemp)"
trap 'rm -f "$api"' EXIT
curl --fail --silent --show-error --get 'https://api.jamendo.com/v3.0/tracks/' \
  --data-urlencode "client_id=$TONEARM_JAMENDO_CLIENT_ID" \
  --data-urlencode 'format=json' \
  --data-urlencode "id=$ids" \
  --data-urlencode 'audioformat=mp32' \
  --data-urlencode 'limit=100' > "$api"
jq -e '.headers.status == "success"' "$api" >/dev/null

mapfile -t expected < <(jq -r '.blends[].tracks[]' "$catalog" | sort -u)
for id in "${expected[@]}"; do
  track="$(jq -ce --arg id "$id" '.results[] | select(.id == $id)' "$api" | head -n 1)"
  [[ -n "$track" ]] || { echo "Jamendo did not resolve track $id" >&2; exit 1; }
  reported_license="$(jq -r '.license_ccurl // empty' <<<"$track")"
  url="$(jq -r '.audio // empty' <<<"$track")"
  [[ "$url" =~ ^https:// ]] || { echo "track $id has no HTTPS audio URL" >&2; exit 1; }
  source="$out/source/$id.mp3"
  asset="$out/audio/$id.m4a"
  echo "==> fetching and transcoding $id"
  curl --fail --location --retry 3 --retry-delay 3 --silent --show-error -o "$source" "$url"
  ffmpeg -nostdin -v error -y -i "$source" -map_metadata -1 -c:a aac -profile:a aac_low -b:a 128k -ar 44100 -ac 2 \
    -movflags +faststart "$asset"
  codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$asset")"
  [[ "$codec" == "aac" ]] || { echo "transcode for $id is not AAC" >&2; exit 1; }
  sha="$(shasum -a 256 "$asset" | awk '{print $1}')"
  bytes="$(stat -c '%s' "$asset")"
  duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$asset")"
  jq -n --arg id "$id" --arg title "$(jq -r '.name' <<<"$track")" \
    --arg artist "$(jq -r '.artist_name' <<<"$track")" --arg license 'CC0' --arg reportedLicense "$reported_license" \
    --arg sha256 "$sha" --argjson bytes "$bytes" --argjson duration "$duration" \
    '{id:$id,title:$title,artist:$artist,license:$license,reportedSourceLicense:$reportedLicense,sha256:$sha256,bytes:$bytes,durationSeconds:$duration,container:"m4a",codec:"aac-lc",sampleRate:44100,channels:2}' \
    > "$out/$id.json"
done

jq -s --arg tag "$tag" --slurpfile catalog "$catalog" \
  '{schemaVersion:1, releaseTag:$tag, audioFormat:"aac-lc-128k-m4a", tracks:., blends:$catalog[0].blends}' \
  "$out"/*.json > "$out/starter-blends-manifest.json"
rm -f "$out"/*.json
rm -rf "$out/source"
echo "Built $(jq '.tracks | length' "$out/starter-blends-manifest.json") AAC assets in $out"
