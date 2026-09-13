#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash Scripts/verify-local-network.sh
swift build --product TextTargetHarness
swift build --product PrivacyHarness
swift build --target PrivacyHarnessTests

pass_report="$(mktemp -t flusterflow-privacy-pass)"
socket_report="$(mktemp -t flusterflow-privacy-socket)"
canary_report="$(mktemp -t flusterflow-privacy-canary)"
setup_failure_report="$(mktemp -t flusterflow-privacy-setup-failure)"
trap 'rm -f "$pass_report" "$socket_report" "$canary_report" "$setup_failure_report"' EXIT

.build/debug/PrivacyHarness -- \
  .build/debug/TextTargetHarness --privacy-smoke >"$pass_report"
jq -e '
  .schemaVersion == 1 and
  .harnessId == "E-PRIVACY-HARNESS" and
  .status == "passed" and
  .childExitCode == 0 and
  .leakCount == 0 and
  .canaryClassCount == 5 and
  .unifiedLogScanned == true and
  .pasteboardChanged == false and
  .networkSampleCount > 0
' "$pass_report" >/dev/null

set +e
.build/debug/PrivacyHarness -- \
  .build/debug/PrivacyHarness --socket-fixture >"$socket_report"
socket_exit=$?
.build/debug/PrivacyHarness -- \
  .build/debug/PrivacyHarness --canary-leak-fixture >"$canary_report"
canary_exit=$?
.build/debug/PrivacyHarness -- \
  /tmp/flusterflow-private-path-secret/nonexistent >"$setup_failure_report"
setup_failure_exit=$?
set -e

if [ "$socket_exit" -ne 1 ]; then
  echo "privacy observer did not reject the loopback socket negative control" >&2
  exit 1
fi
jq -e '
  .status == "failed" and
  ([.leaks[].kind] | index("networkSocket")) != null
' "$socket_report" >/dev/null

if [ "$canary_exit" -ne 1 ]; then
  echo "privacy scanner did not reject the canary leak negative control" >&2
  exit 1
fi
jq -e '
  .status == "failed" and
  ([.leaks[].kind] | index("temporaryFile")) != null
' "$canary_report" >/dev/null

if [ "$setup_failure_exit" -ne 2 ]; then
  echo "privacy harness did not reject the missing child executable" >&2
  exit 1
fi
jq -e '
  .status == "failed" and
  .limitations == ["Harness setup failed: runtime-operation."]
' "$setup_failure_report" >/dev/null
if grep -q -F '/tmp/flusterflow-private-path-secret' "$setup_failure_report"; then
  echo "privacy harness exposed a child path in its failure report" >&2
  exit 1
fi

cat "$pass_report"
echo "dynamic local privacy + negative controls: PASS"
