#!/usr/bin/env bash
# Regression contract: only issues authored by the repository owner
# (johnarleyburns) may be admitted into the automated coding pipeline.
set -euo pipefail

script=.github/scripts/admit-one-stranded-issue.sh
grep -Fq -- 'select(.author.login == "johnarleyburns")' "$script"

admit() {
  jq -r '
sort_by([if any(.labels[]?.name; . == "priority-high") then 0 elif any(.labels[]?.name; . == "qa-failed") then 1 else 2 end, .createdAt, .number])[]
| select(.author.login == "johnarleyburns")
| select(any(.labels[]?.name; . == "awaiting-ci-authorization" or . == "tracking" or . == "blocked-by-dependency" or . == "intake-running" or . == "intake-retry-deferred") | not)
| select((any(.labels[]?.name; . == "ready-for-qa") | not) or any(.labels[]?.name; . == "qa-failed"))
| select((any(.labels[]?.name; . == "needs-human-review") | not) or any(.labels[]?.name; . == "retry-ai"))
| select((any(.labels[]?.name; . == "intake-blocked") | not) or any(.labels[]?.name; . == "retry-ai")) | .number'
}

actual=$(admit <<'JSON'
[
  {"number": 10, "author": {"login": "johnarleyburns"}, "createdAt": "2026-01-01T00:00:00Z", "labels": []},
  {"number": 11, "author": {"login": "some-other-user"}, "createdAt": "2026-01-01T00:00:01Z", "labels": []},
  {"number": 12, "author": {"login": "johnarleyburns"}, "createdAt": "2026-01-02T00:00:00Z", "labels": [{"name": "ready-for-qa"}]}
]
JSON
)
expected=$'10'
[[ "$actual" == "$expected" ]] || { echo "unexpected admission author filtering: $actual" >&2; exit 1; }
echo 'issue backlog author policy: ok'
