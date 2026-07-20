#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $0 RUN_ID SCENARIO_ID SURFACE STATUS OUTCOME CONFIRMED_MUTATION OUTPUT.json" >&2
  exit 64
fi

run_id="$1"
scenario_id="$2"
surface="$3"
status="$4"
outcome="$5"
confirmed="$6"
output="$7"

case "$status" in
  passed|failed|manual|tccRequired) ;;
  *) echo "invalid status" >&2; exit 64 ;;
esac

case "$outcome" in
  directAX|validatedAXValue|guardedCGEvent|guardedPaste|safeFallback|insertionDenied|ignoredStaleSession|contextOnly) ;;
  *) echo "invalid outcome" >&2; exit 64 ;;
esac

case "$confirmed" in
  true|false) ;;
  *) echo "CONFIRMED_MUTATION must be true or false" >&2; exit 64 ;;
esac

jq -n \
  --arg runId "$run_id" \
  --arg scenarioId "$scenario_id" \
  --arg surface "$surface" \
  --arg status "$status" \
  --arg outcome "$outcome" \
  --argjson confirmedMutation "$confirmed" \
  '{
    schemaVersion: 1,
    harnessId: "E-TARGET-HARNESS",
    runId: $runId,
    scenarioId: $scenarioId,
    surface: $surface,
    status: $status,
    outcome: $outcome,
    confirmedMutation: $confirmedMutation,
    pasteboardChanged: false,
    assertions: [{
      id: "manual-observation",
      passed: ($status == "passed"),
      detail: "Recorded manually without target text content"
    }],
    residual: (if $status == "passed" then null else "Manual follow-up required" end)
  }' >"$output"
