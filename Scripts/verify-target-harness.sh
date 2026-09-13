#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TextTargetHarness
swift build --target TextTargetHarnessTests

failure_report="$(mktemp -t flusterflow-target-failure)"
trap 'rm -f "$failure_report"' EXIT

.build/debug/TextTargetHarness \
  --validate-contract \
  --scenarios TestSupport/TextTargetHarness/scenarios.json

jq -e '
  .schemaVersion == 1 and
  .harnessId == "E-TARGET-HARNESS" and
  (.scenarios | length) == 28 and
  ([.scenarios[].id] | length) == ([.scenarios[].id] | unique | length)
' TestSupport/TextTargetHarness/scenarios.json >/dev/null

jq -e '
  .schemaVersion == 1 and
  .harnessId == "E-TARGET-EXTERNAL-MANUAL" and
  (.scenarios | length) >= 4 and
  ([.scenarios[].id] | length) == ([.scenarios[].id] | unique | length)
' TestSupport/TextTargetHarness/external-scenarios.json >/dev/null

jq -e '.properties.status.enum | index("tccRequired") != null' \
  TestSupport/TextTargetHarness/result.schema.json >/dev/null

set +e
.build/debug/TextTargetHarness \
  --validate-contract \
  --scenarios /tmp/flusterflow-private-path-secret/missing.json >"$failure_report"
failure_exit=$?
set -e

if [ "$failure_exit" -ne 1 ]; then
  echo "target harness did not reject a missing scenario contract" >&2
  exit 1
fi
jq -e '
  .status == "failed" and
  .assertions == [{
    "detail": "Harness command failed: runtime-operation.",
    "id": "command",
    "passed": false
  }]
' "$failure_report" >/dev/null
if grep -q -F '/tmp/flusterflow-private-path-secret' "$failure_report"; then
  echo "target harness exposed a scenario path in its failure report" >&2
  exit 1
fi

echo "target harness contract/build: PASS"

if [ "${RUN_AX_HARNESS:-0}" = "1" ]; then
  bash Scripts/run-target-ax-smoke.sh
fi

if [ "${RUN_XCODE_HARNESS:-0}" = "1" ]; then
  derived_data="${HARNESS_DERIVED_DATA:-/tmp/WhisperFlowHarnessDerivedData}"
  xcodebuild \
    -workspace TestSupport/VerificationHarnesses.xcworkspace \
    -scheme TextTargetHarness \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
  xcodebuild \
    -workspace TestSupport/VerificationHarnesses.xcworkspace \
    -scheme PrivacyHarness \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
fi
