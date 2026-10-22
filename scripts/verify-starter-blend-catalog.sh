#!/usr/bin/env bash
# Verifies the curated starter runs against a versioned source-index export.
# This is a curation-time check; it does not run in the app or block playback.
set -euo pipefail

catalog="${1:-Config/starter-blend-source.json}"
index="${2:?usage: verify-starter-blend-catalog.sh [catalog.json] <source-index.json.gz>}"

command -v gzip >/dev/null
command -v jq >/dev/null
[[ -f "$catalog" ]] || { echo "missing $catalog" >&2; exit 2; }
[[ -f "$index" ]] || { echo "missing $index" >&2; exit 2; }

gzip -dc "$index" | jq --slurpfile catalog "$catalog" '
  def camelot:
    capture("^(?<number>1[0-2]|[1-9])(?<letter>[AB])$")
    | {number: (.number | tonumber), letter: .letter};
  def keysCompatible($from; $to):
    ($from | camelot) as $a | ($to | camelot) as $b
    | if $a.letter == $b.letter then
        (($a.number - $b.number | abs) == 0
         or ($a.number - $b.number | abs) == 1
         or ($a.number - $b.number | abs) == 11)
      else $a.number == $b.number
      end;
  INDEX(.[]; (.id | sub("^jamendo-"; ""))) as $byID
  | [ $catalog[0].blends[]
      | . as $blend
      | [ .tracks[] | $byID[.] ] as $tracks
      | {
          id: $blend.id,
          subgenre: $blend.genre,
          trackCount: ($tracks | length),
          missing: [$tracks[] | select(. == null)],
          wrongSubgenre: [$tracks[] | select(. != null and .genre != $blend.genre) | .id],
          invalidEdges: [range(0; ($tracks | length) - 1) as $i
            | $tracks[$i] as $from | $tracks[$i + 1] as $to
            | select($from == null or $to == null
                     or (($to.bpm / $from.bpm - 1) | abs) > 0.08 + 1e-9
                     or (keysCompatible($from.key; $to.key) | not))
            | {from: ($from.id // "missing"), to: ($to.id // "missing")}]
        }
    ]
  | .[] as $result
  | if ($result.trackCount == 6 and ($result.missing | length) == 0
        and ($result.wrongSubgenre | length) == 0 and ($result.invalidEdges | length) == 0)
    then "OK \($result.id): \($result.subgenre), 6 compatible tracks"
    else "INVALID \($result | tojson)" | error
    end
'
