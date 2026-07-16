.PHONY: test-integration

REMOTE_TEST_URL ?= http://127.0.0.1:18089

test-integration:
	set -e; \
	docker compose -f docker-compose.remote-test.yml up -d --wait; \
	trap 'docker compose -f docker-compose.remote-test.yml down' EXIT; \
	TONEARM_REMOTE_INTEGRATION_BASE_URL=$(REMOTE_TEST_URL) swift test --filter RemoteIntegrationTests
