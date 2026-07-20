#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product TextTargetHarness

ready_file="$(mktemp -t flusterflow-target-ready)"
error_file="$(mktemp -t flusterflow-target-error)"
harness_pid=""

cleanup() {
  if [ -n "$harness_pid" ] && kill -0 "$harness_pid" 2>/dev/null; then
    kill "$harness_pid" 2>/dev/null || true
    wait "$harness_pid" 2>/dev/null || true
  fi
  rm -f "$ready_file" "$error_file"
}
trap cleanup EXIT

.build/debug/TextTargetHarness --automation >"$ready_file" 2>"$error_file" &
harness_pid=$!

for _ in $(seq 1 60); do
  if rg -q '^READY ' "$ready_file"; then
    break
  fi
  if ! kill -0 "$harness_pid" 2>/dev/null; then
    echo "TextTargetHarness exited before becoming ready" >&2
    sed -n '1,80p' "$error_file" >&2
    exit 1
  fi
  sleep 0.1
done

if ! rg -q '^READY ' "$ready_file"; then
  echo "TextTargetHarness readiness timeout" >&2
  exit 1
fi

set +e
.build/debug/TextTargetHarness --probe-pid "$harness_pid"
probe_exit=$?
set -e

if [ "$probe_exit" -eq 77 ]; then
  echo "AX smoke requires Accessibility permission for .build/debug/TextTargetHarness" >&2
  exit 77
fi
exit "$probe_exit"
