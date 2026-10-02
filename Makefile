.PHONY: ci-guards models starter project test-local test-swift test-ui test-integration test-ui-regression

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

# Fetch the Mood Starter databases pinned in Config/starter.lock into Resources/Starter/
# (StarterLibrary). Build them with `swift run -c release BuiltInAnalyzer build-starter …`.
starter:
	scripts/fetch-starter.sh

# Regenerate Tonearm.xcodeproj. USE THIS RATHER THAN BARE `xcodegen generate`:
# it first writes Config/models-odr.yml from which converted model packages are
# on this machine (scripts/generate-project.sh explains why), then generates.
project:
	scripts/generate-project.sh

test-local:
	scripts/run-local-test-suite.sh full

test-swift:
	scripts/run-local-test-suite.sh swift

test-ui:
	scripts/run-local-test-suite.sh ui

REMOTE_TEST_URL ?= http://127.0.0.1:18089

test-integration:
	set -e; \
	docker compose -f docker-compose.remote-test.yml up -d --wait; \
	trap 'docker compose -f docker-compose.remote-test.yml down' EXIT; \
	TONEARM_REMOTE_INTEGRATION_BASE_URL=$(REMOTE_TEST_URL) swift test --filter RemoteIntegrationTests

# UI regression suite (spec §53). Run by hand before a release — never in CI,
# never in a git hook. Needs Docker + a simulator; lanes with missing
# prerequisites skip rather than fail.
#   make test-ui-regression
#   make test-ui-regression LANES=remote
#
LANES ?= all

test-ui-regression:
	LANES=$(LANES) scripts/run-ui-regression.sh
