.PHONY: test-local test-swift test-ui test-integration

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
