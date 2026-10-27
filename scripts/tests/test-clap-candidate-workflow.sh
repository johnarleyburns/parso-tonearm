#!/usr/bin/env bash
# Structural policy for the manual CLAP candidate workflow.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
wf="$root/.github/workflows/clap-candidate-model.yml"
ruby -ryaml -e '
w = YAML.safe_load(File.read(ARGV[0]), aliases: true)
on = w[true] || w["on"]
abort "must be workflow_dispatch only" unless on.keys == ["workflow_dispatch"]
abort "permissions" unless w["permissions"] == {"contents" => "write"}
abort "top-level env must not hold token" if w.fetch("env", {}).key?("GH_TOKEN")
job = w["jobs"]["candidate"]
abort "runner" unless job["runs-on"] == "xcode-27"
abort "job env token" if job.key?("env")
holders = job["steps"].select { |s| (s["env"] || {}).key?("GH_TOKEN") }.map { |s| s["name"] }
abort "GH_TOKEN scope: #{holders}" unless holders == ["Fail early if the release already exists", "Publish prerelease"]
' "$wf"
grep -Fq 4226474e38defca6fc9272a7848bb7b0355ccd7a "$wf"
grep -Fq fae3e9c087f2909c28a09dc31c8dfcdacbc42ba44c70e972b58c1bd1caf6dedd "$wf"
grep -Fq 'gh release create "$RELEASE_TAG"' "$wf"
grep -Fq -- '--prerelease' "$wf"
grep -Fq 'precision:' "$wf"
grep -Fq -- '--precision "$PRECISION"' "$wf"
! grep -Eq 'models\.lock|gh release (edit|upload|delete)|--clobber' "$wf"
# Converter step must not see the token.
! sed -n '/name: Generate and verify candidate/,/name: Validate package/p' "$wf" | grep -q GH_TOKEN
req="$root/tools/clap-coreml/requirements-candidate.txt"
! grep -Ev '^\s*(#|$)' "$req" | grep -Evq '=='
for f in "$root/tools/clap-coreml/generate_candidate_audio.py" "$root/tools/clap-coreml/generate_candidate_text.py" "$root/tools/clap-coreml/generate_candidate_common.py"; do
  test -f "$f"
  python3 -m py_compile "$f"
done
echo "clap candidate workflow policy OK"
