#!/bin/bash
# Generates live UI evidence (screenshots) for the test suite.
# Tests read PI_UI_EVIDENCE_DIR; xcodebuild only forwards env vars prefixed with TEST_RUNNER_.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/evidence}"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
DD="$(mktemp -d)"
trap 'rm -rf "$DD"' EXIT
TEST_RUNNER_PI_UI_EVIDENCE_DIR="$OUT_ABS" xcodebuild \
  -project PlayerIdentity.xcodeproj -scheme PlayerIdentity \
  -destination 'platform=macOS' -derivedDataPath "$DD" test \
  2>&1 | tee /tmp/playeridentity-evidence.log | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" || true
COUNT=$(find "$OUT_ABS" -name '*.png' | wc -l | tr -d ' ')
echo "Evidence PNGs: $COUNT in $OUT_ABS"
if [ "$COUNT" -eq 0 ]; then echo "ERROR: no evidence was written (env var not forwarded?)" >&2; exit 1; fi
