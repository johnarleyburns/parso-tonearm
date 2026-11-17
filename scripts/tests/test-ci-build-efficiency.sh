#!/usr/bin/env bash
# Exercise the shipping validation build driver without requiring Apple SDKs.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
export TONEARM_BUILD_TEST_LOG="$fixture/build.log"
cat > "$fixture/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TONEARM_BUILD_TEST_LOG"
exit "${TONEARM_BUILD_TEST_EXIT:-0}"
STUB
chmod +x "$fixture/bin/xcodebuild"
PATH="$fixture/bin:$PATH" bash "$root/scripts/build-apps-for-validation.sh"
test "$(wc -l < "$TONEARM_BUILD_TEST_LOG" | tr -d ' ')" = 2
grep -q -- '-scheme Tonearm -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO$' "$TONEARM_BUILD_TEST_LOG"
grep -q -- '-scheme TonearmWatch -destination generic/platform=watchOS CODE_SIGNING_ALLOWED=NO$' "$TONEARM_BUILD_TEST_LOG"
if grep -Eq -- 'Simulator|simulator|-sdk|ARCHS=|ONLY_ACTIVE_ARCH=' "$TONEARM_BUILD_TEST_LOG"; then
    echo 'CI must compile generic devices with default device architectures and no global SDK override' >&2
    exit 1
fi
: > "$TONEARM_BUILD_TEST_LOG"
if PATH="$fixture/bin:$PATH" TONEARM_BUILD_TEST_EXIT=42 bash "$root/scripts/build-apps-for-validation.sh"; then
    echo 'Validation must propagate build failures' >&2
    exit 1
fi
test "$(wc -l < "$TONEARM_BUILD_TEST_LOG" | tr -d ' ')" = 1
# The standalone harness still runs before the full suite, which excludes only that target.
python3 - "$root" <<'PY'
from pathlib import Path
import sys
text = (Path(sys.argv[1]) / 'scripts/ci-validate.sh').read_text()
assert 'bash scripts/build-apps-for-validation.sh' in text
assert 'bash scripts/tests/test-ci-build-efficiency.sh' in text
assert text.index('bash scripts/run-production-regression.sh') < text.index('swift test --skip TonearmProductionRegressionTests')
PY
echo 'CI validation builds device targets only and preserves failure propagation'
