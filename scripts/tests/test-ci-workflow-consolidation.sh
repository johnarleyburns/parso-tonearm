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
check.call(test_job.fetch('runs-on') == 'xcode-27', 'Post-merge tests must run on the Xcode 27 runner')
archive = release.fetch('jobs').fetch('testflight-build')
check.call(Array(archive.fetch('needs')) == ['test'], 'Signing/upload must depend on successful merged-code tests')
check.call(!archive.fetch('if', '').match?(/always\(|failure\(|cancelled\(/), 'Release must not bypass a failed test dependency')
check.call(archive.fetch('runs-on') == 'xcode-27', 'TestFlight archive/upload must run on the Xcode 27 runner')
check.call(archive.fetch('steps').any? { |step| step['name'] == 'Upload to TestFlight' }, 'Retain the TestFlight upload path')
archive_run = archive.fetch('steps').find { |step| step['name'] == 'Archive' }.fetch('run')
check.call(!archive_run.include?('IPHONEOS_DEPLOYMENT_TARGET=18.0'), 'Archive must not override project.yml with the old iOS 18 deployment target')
project = YAML.safe_load(File.read(File.join(root, 'project.yml')), aliases: true)
check.call(project.fetch('settings').fetch('base').fetch('IPHONEOS_DEPLOYMENT_TARGET') == '27.0', 'project.yml must stay on the iOS 27 deployment target')
xcode_steps = [test_job, archive].flat_map { |job| job.fetch('steps') }.select { |step| step['name'] == 'Select Xcode 27' }
check.call(xcode_steps.length == 2, 'Both main jobs must select Xcode 27 explicitly')
check.call(xcode_steps.all? { |step| step.fetch('run', '').include?('XCODE_MAJOR') }, 'Xcode selection must fail when the runner has an older SDK')
puts 'CI workflows: one PR verification path; main tests gate TestFlight on Xcode 27'
RUBY
