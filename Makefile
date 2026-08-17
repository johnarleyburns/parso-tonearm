.PHONY: models project test-local test-swift test-ui test-integration test-ui-regression

# Fetch the converted Core ML packages pinned in Config/models.lock into
# Resources/Models/. No model is committed — GitHub rejects files over 100 MB —
# so a fresh clone needs this before the ODR tags can be in the project. A
# package already on this machine is kept (`scripts/fetch-models.sh --force`
# replaces it).
models:
	scripts/fetch-models.sh

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
# The DJ live-mix lanes (§53.7–53.12) additionally need a real-time audio device
# and minutes of wall clock, which is exactly why they are not in CI either:
#   make test-ui-regression LANES=djmix                  # gates M5
#   make test-ui-regression LANES=djmix MIX_MINUTES=20   # pre-release soak
#   make test-ui-regression LANES=djlive                 # real Jamendo; informs only
#   make test-ui-regression LANES=djhw                   # M6: cue, MIDI, purchase row
# djmix keeps its recorded mix at build/ui-regression/dj/ so you can listen to it.
LANES ?= all
MIX_MINUTES ?= 6

test-ui-regression:
	LANES=$(LANES) MIX_MINUTES=$(MIX_MINUTES) scripts/run-ui-regression.sh
