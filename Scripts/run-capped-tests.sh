#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/WhisperFlow.xcodeproj"
DEFAULT_PLAN="$ROOT_DIR/WhisperFlow.xctestplan"
FULL_PLAN_NAME="WhisperFlow-Full"
DEFAULT_PLAN_NAME="WhisperFlow"
MAX_DEFAULT_TESTS=150
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"

mode="default"
if [[ "${1:-}" == "--verify-only" ]]; then
  mode="verify"
elif [[ "${1:-}" == "--full" ]]; then
  mode="full"
elif [[ "${1:-}" != "" ]]; then
  echo "usage: $0 [--verify-only|--full]" >&2
  exit 64
fi

count_output="$(
  ROOT_DIR="$ROOT_DIR" DEFAULT_PLAN="$DEFAULT_PLAN" /usr/bin/python3 <<'PY'
import json
import os
import re
import sys
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
plan = json.loads(Path(os.environ["DEFAULT_PLAN"]).read_text())
source_files = list((root / "WhisperFlowTests").rglob("*Tests.swift"))
methods_by_class = {}
pattern = re.compile(r"^\s*func\s+(test\w+)\s*\(")
for source in source_files:
    class_name = source.stem
    methods = []
    for line in source.read_text().splitlines():
        match = pattern.match(line)
        if match:
            methods.append(f"{class_name}/{match.group(1)}()")
    methods_by_class[class_name] = methods

selected = []
missing = []
for target in plan["testTargets"]:
    for item in target.get("selectedTests", []):
        if "/" in item:
            class_name = item.split("/", 1)[0]
            if item in methods_by_class.get(class_name, []):
                selected.append(item)
            else:
                missing.append(item)
        else:
            methods = methods_by_class.get(item)
            if methods:
                selected.extend(methods)
            else:
                missing.append(item)

if missing:
    print("missing selected tests:", file=sys.stderr)
    for name in missing:
        print(name, file=sys.stderr)
    raise SystemExit(1)

unique = sorted(set(selected))
print(len(unique))
for name in unique:
    print(name)
PY
)"

selected_count="$(printf '%s\n' "$count_output" | sed -n '1p')"
if [[ "$selected_count" -gt "$MAX_DEFAULT_TESTS" ]]; then
  echo "Default test plan selects $selected_count tests; max is $MAX_DEFAULT_TESTS." >&2
  exit 1
fi

echo "Default test plan selects $selected_count tests (max $MAX_DEFAULT_TESTS)."
if [[ "$mode" == "verify" ]]; then
  printf '%s\n' "$count_output" | sed '1d'
  exit 0
fi

plan_name="$DEFAULT_PLAN_NAME"
if [[ "$mode" == "full" ]]; then
  plan_name="$FULL_PLAN_NAME"
fi

cd "$ROOT_DIR"
xcodebuild test \
  -project "$PROJECT" \
  -scheme WhisperFlow \
  -testPlan "$plan_name" \
  -configuration Debug \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO
