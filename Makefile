.PHONY: tonearm-production-regression ci-guards models project test-local test-swift test-integration

# Hermetic production-flow + visual regression harness (issue #80). Mandatory evidence for issue
# work; a generic `swift test` pass does not substitute for it. See CLAUDE.md.
tonearm-production-regression:
	scripts/run-production-regression.sh

# The structural guards CI runs before it spends a test job on you: the Swift 6
# contract, the StoreKit import boundary, and the codename leak. Under a second.
ci-guards:
	scripts/check-ci-guards.sh

# Fetch the converted Core ML packages pinned in Config/models.lock into
# Resources/Models/. No model is committed — GitHub rejects files over 100 MB —
# so a fresh clone needs this before the ODR tags can be in the project. A
# package already on this machine is kept (`scripts/fetch-models.sh --force`
# replaces it).
models:
	scripts/fetch-models.sh

# Regenerate Tonearm.xcodeproj. USE THIS RATHER THAN BARE `xcodegen generate`:
# it first writes Config/models-bundled.yml / models-odr.yml from which converted model packages are
# on this machine (scripts/generate-project.sh explains why), then generates.
project:
	scripts/generate-project.sh

test-local:
	scripts/run-local-test-suite.sh full

test-swift:
	scripts/run-local-test-suite.sh swift

REMOTE_TEST_URL ?= http://127.0.0.1:18089

test-integration:
	set -e; \
	docker compose -f docker-compose.remote-test.yml up -d --wait; \
	trap 'docker compose -f docker-compose.remote-test.yml down' EXIT; \
	TONEARM_REMOTE_INTEGRATION_BASE_URL=$(REMOTE_TEST_URL) swift test --filter RemoteIntegrationTests
