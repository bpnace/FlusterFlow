#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

forbidden_path_pattern='(^|/)(\.omx|\.codex|\.claude|\.cursor|\.idea|\.vscode|xcuserdata|DerivedData|\.build)(/|$)|(^|/)\.DS_Store$|\.(xcarchive|xcresult|app)(/|$)|\.(env|pem|key|p12|pfx|cer|crt|der|keychain|keychain-db|mobileprovision|wav|aiff|aif|caf|m4a|mp3|flac|dmg|pkg|zip|tar|tgz|trace|profraw|profdata|log)$'

tracked_forbidden_paths="$(git ls-files | grep -E "$forbidden_path_pattern" || true)"
if [ -n "$tracked_forbidden_paths" ]; then
  printf '%s\n' "tracked local/private artifacts are forbidden:" >&2
  printf '%s\n' "$tracked_forbidden_paths" >&2
  exit 1
fi

internal_reference_pattern='(/Users/|~/?\.codex/|(^|[^[:alnum:]_])\.omx/)'
tracked_internal_references="$(
  git grep --cached -n -I -E "$internal_reference_pattern" -- . \
    ':(exclude).gitignore' \
    ':(exclude)Scripts/verify-repository-hygiene.sh' \
    || true
)"
if [ -n "$tracked_internal_references" ]; then
  printf '%s\n' "tracked local agent or workstation references are forbidden:" >&2
  printf '%s\n' "$tracked_internal_references" >&2
  exit 1
fi

printf '%s\n' "repository hygiene: PASS"
