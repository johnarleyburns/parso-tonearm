#!/usr/bin/env bash
# TestFlight exports directly from the archive; no intermediate IPA is required.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
ruby -ryaml - "$root" <<'RUBY'
root = ARGV.fetch(0)
workflow = YAML.safe_load(File.read(File.join(root, '.github/workflows/ios.yml')), aliases: true)
steps = workflow.fetch('jobs').fetch('testflight-build').fetch('steps')
exports = steps.select { |step| step.fetch('run', '').include?('xcodebuild -exportArchive') }
abort 'Expected one export/upload command, with no standalone IPA export' unless exports.length == 1
upload = steps.find { |step| step['name'] == 'Upload to TestFlight' }.fetch('run')
required = ['cp ExportOptions.plist "$upload_options"',
            "Add :destination string upload", 'bash .github/scripts/testflight-upload.sh --',
            'xcodebuild -exportArchive', '-archivePath ./build/Tonearm.xcarchive',
            '-exportOptionsPlist "$upload_options"', '-authenticationKeyPath',
            '-authenticationKeyID', '-authenticationKeyIssuerID']
required.each { |text| abort "Missing upload contract: #{text}" unless upload.include?(text) }
abort 'Archive must still precede upload' unless steps.index { |s| s['name'] == 'Archive' } < steps.index { |s| s['name'] == 'Upload to TestFlight' }
abort 'Keep delivery evidence tied to the archived app' unless steps.any? { |s| s['env'] && s['env']['ARCHIVED_APP'] == './build/Tonearm.xcarchive/Products/Applications/Tonearm.app' }
puts 'TestFlight exports/uploads the archive once; signing options and traceability retained'
RUBY
