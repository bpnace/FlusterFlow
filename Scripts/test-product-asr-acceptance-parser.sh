#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-product-asr-acceptance.sh"

export FLUSTERFLOW_PRODUCT_ASR_ACCEPTANCE_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"

TMP_DIR="$(mktemp -d /tmp/flusterflow-product-asr-parser.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_fixture() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$TMP_DIR/$name.log"
}

assert_passes() {
  local name="$1"
  if ! product_asr_smoke_passed "$TMP_DIR/$name.log"; then
    echo "Expected parser to accept $name" >&2
    exit 1
  fi
}

assert_rejects() {
  local name="$1"
  if product_asr_smoke_passed "$TMP_DIR/$name.log"; then
    echo "Expected parser to reject $name" >&2
    exit 1
  fi
}

write_fixture legacy-xctest \
  "Test Suite 'Selected tests' started at 2026-07-22 10:00:00.000." \
  "Test Case '-[WhisperFlowTests.WhisperKitRecognizerTests testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested]' started." \
  "Test Case '-[WhisperFlowTests.WhisperKitRecognizerTests testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested]' passed (12.345 seconds)." \
  "Test Suite 'Selected tests' passed at 2026-07-22 10:00:12.345." \
  "Executed 1 test, with 0 failures (0 unexpected) in 12.345 (12.346) seconds"

write_fixture xcode-compact \
  "    t = 0.00s Start Test at 2026-07-22 10:00:00.000" \
  "    t = 0.01s Test testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested() started" \
  "    t = 3.42s Test testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested() passed after 3.41 seconds"

write_fixture skipped \
  "Test Case '-[WhisperFlowTests.WhisperKitRecognizerTests testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested]' skipped (0.001 seconds)." \
  "Test Suite 'Selected tests' passed at 2026-07-22 10:00:00.001." \
  "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"

write_fixture not-run \
  "Test Suite 'Selected tests' passed at 2026-07-22 10:00:00.001." \
  "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"

write_fixture suite-only-pass \
  "Test Suite 'WhisperFlowTests.WhisperKitRecognizerTests' passed at 2026-07-22 10:00:00.001." \
  "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"

assert_passes legacy-xctest
assert_passes xcode-compact
assert_rejects skipped
assert_rejects not-run
assert_rejects suite-only-pass

echo "Product ASR acceptance parser fixtures: PASS"
