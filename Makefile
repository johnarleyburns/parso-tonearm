.PHONY: test-local test-swift test-ui test-integration test-ui-regression

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
LANES ?= all

test-ui-regression:
	LANES=$(LANES) scripts/run-ui-regression.sh
