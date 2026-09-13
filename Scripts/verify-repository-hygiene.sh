#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="${1:-index}"
if [ "$mode" != "index" ] && [ "$mode" != "--history" ]; then
  printf '%s\n' "usage: $0 [--history]" >&2
  exit 64
fi

forbidden_path_pattern='(^|/)(\.omx|\.codex|\.claude|\.cursor|\.idea|\.vscode|xcuserdata|DerivedData|build|\.build|\.swiftpm|Models)(/|$)|(^|/)(\.DS_Store|keychain-password|\.envrc)$|(^|/)([^/]*\.env|\.env\.[^/]+)$|(^|/)[^/]*\.(xcuserstate|xccheckout|xcscmblueprint|pem|key|p12|pfx|cer|crt|der|keychain|keychain-db|mobileprovision|wav|aiff|aif|caf|m4a|mp3|flac|dmg|pkg|zip|tar|tgz|trace|profraw|profdata|log)$|(^|/)[^/]*\.(xcarchive|xcresult|app|mlmodelc)(/|$)'
internal_reference_pattern='(/Users/|~/?\.codex/|(^|[^[:alnum:]_])\.omx/)'

set +e
tracked_paths="$(git ls-files 2>/dev/null)"
tracked_paths_status=$?
set -e
if [ "$tracked_paths_status" -ne 0 ]; then
  printf '%s\n' "repository path hygiene check failed" >&2
  exit "$tracked_paths_status"
fi
set +e
printf '%s\n' "$tracked_paths" | grep -E "$forbidden_path_pattern" >/dev/null
path_status=$?
set -e
if [ "$path_status" -eq 0 ]; then
  printf '%s\n' "tracked local/private artifacts are forbidden" >&2
  exit 1
elif [ "$path_status" -ne 1 ]; then
  printf '%s\n' "repository path hygiene check failed" >&2
  exit "$path_status"
fi

set +e
git grep --cached -I -q -E "$internal_reference_pattern" -- . \
  ':(exclude).gitignore' \
  ':(exclude)Scripts/verify-repository-hygiene.sh'
reference_status=$?
set -e
if [ "$reference_status" -eq 0 ]; then
  printf '%s\n' "tracked local agent or workstation references are forbidden" >&2
  exit 1
elif [ "$reference_status" -ne 1 ]; then
  printf '%s\n' "repository content hygiene check failed" >&2
  exit "$reference_status"
fi

if [ "$mode" = "--history" ]; then
  set +e
  history_objects="$(git rev-list --objects --all 2>/dev/null)"
  history_objects_status=$?
  set -e
  if [ "$history_objects_status" -ne 0 ]; then
    printf '%s\n' "repository history path check failed" >&2
    exit "$history_objects_status"
  fi
  set +e
  printf '%s\n' "$history_objects" \
    | sed -E 's/^[0-9a-f]+ //' \
    | grep -E "$forbidden_path_pattern" >/dev/null
  history_path_status=$?
  set -e
  if [ "$history_path_status" -eq 0 ]; then
    printf '%s\n' "repository history contains local/private artifact paths" >&2
    exit 1
  elif [ "$history_path_status" -ne 1 ]; then
    printf '%s\n' "repository history path check failed" >&2
    exit "$history_path_status"
  fi

  set +e
  commits="$(git rev-list --all 2>/dev/null)"
  commits_status=$?
  set -e
  if [ "$commits_status" -ne 0 ]; then
    printf '%s\n' "repository history content check failed" >&2
    exit "$commits_status"
  fi
  while IFS= read -r commit; do
    set +e
    git grep -I -q -E "$internal_reference_pattern" "$commit" -- . \
      ':(exclude).gitignore' \
      ':(exclude)Scripts/verify-repository-hygiene.sh'
    history_reference_status=$?
    set -e
    if [ "$history_reference_status" -eq 0 ]; then
      printf '%s\n' "repository history contains local agent or workstation references" >&2
      exit 1
    elif [ "$history_reference_status" -ne 1 ]; then
      printf '%s\n' "repository history content check failed" >&2
      exit "$history_reference_status"
    fi
  done <<< "$commits"
fi

printf '%s\n' "repository hygiene: PASS"
