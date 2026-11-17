#!/usr/bin/env bash
# Parse the actual workflows: PRs validate once; releases still require tests.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
ruby -ryaml - "$root" <<'RUBY'
root = ARGV.fetch(0)
load_workflow = ->(name) { YAML.safe_load(File.read(File.join(root, '.github/workflows', name)), aliases: true) }
triggers = ->(workflow) { workflow.fetch('on') { workflow.fetch(true) } }
check = ->(condition, message) { abort message unless condition }
pr = load_workflow.call('pr-validation.yml')
release = load_workflow.call('ios.yml')
pr_on = triggers.call(pr)
release_on = triggers.call(release)
check.call(pr_on.fetch('pull_request').fetch('branches').include?('main'), 'PR validation must still target main')
check.call(!release_on.key?('pull_request') && !release_on.key?('pull_request_target'), 'PRs must not run the duplicate release test workflow')
check.call(release_on.fetch('push').fetch('branches') == ['main'], 'Merged main must still trigger release verification')
check.call(release_on.key?('workflow_dispatch'), 'Manual release dispatch must remain available')
steps = pr.fetch('jobs').fetch('validate').fetch('steps')
check.call(steps.count { |step| step['run'] == 'bash scripts/ci-validate.sh' } == 1, 'Keep one required validate invocation')
test_job = release.fetch('jobs').fetch('test')
check.call(!test_job.key?('if'), 'Post-merge tests must not be conditionally bypassed')
check.call(test_job.fetch('steps').any? { |step| step.fetch('run', '').include?('swift test') }, 'Release verification must run the Swift suite')
archive = release.fetch('jobs').fetch('testflight-build')
check.call(Array(archive.fetch('needs')) == ['test'], 'Signing/upload must depend on successful merged-code tests')
check.call(!archive.fetch('if', '').match?(/always\(|failure\(|cancelled\(/), 'Release must not bypass a failed test dependency')
check.call(archive.fetch('steps').any? { |step| step['name'] == 'Upload to TestFlight' }, 'Retain the TestFlight upload path')
puts 'CI workflows: one PR verification path; main tests gate TestFlight'
RUBY
