#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failures=0

while IFS= read -r match; do
  [ -z "$match" ] && continue
  path="${match%%:*}"
  case "$path" in
    WhisperFlow/Integrations/OpenAI/OpenAITransport.swift) ;;
    WhisperFlow/Integrations/ModelProvisioning/HTTPSModelProvisioningTransport.swift) ;;
    *)
      echo "network capability outside approved boundary: $match" >&2
      failures=$((failures + 1))
      ;;
  esac
done <<EOF
$(rg -n --glob '*.swift' 'URLSession|URLRequest|HTTPURLResponse|import[[:space:]]+Network|NWConnection|NWPathMonitor' WhisperFlow || true)
EOF

while IFS= read -r match; do
  [ -z "$match" ] && continue
  echo "forbidden cloud DTO field: $match" >&2
  failures=$((failures + 1))
done <<EOF
$(rg -n --glob '*.swift' '(^|[[:space:]])(let|var)[[:space:]]+(audio|rawTranscript|raw_transcript|bundleIdentifier|windowTitle|filePath|deviceIdentifier)[[:space:]]*:' WhisperFlow/Core/Cloud WhisperFlow/Integrations/OpenAI || true)
EOF

if rg -n --glob '*.swift' 'UserDefaults' WhisperFlow/Core/Security >/dev/null; then
  echo "security boundary must not persist secrets in UserDefaults" >&2
  failures=$((failures + 1))
fi

if ! rg -n 'store:[[:space:]]*false' WhisperFlow/Integrations/OpenAI/OpenAITransport.swift >/dev/null; then
  echo "OpenAI request must hard-code store:false" >&2
  failures=$((failures + 1))
fi

if rg -n 'URLSession\.shared|session:[[:space:]]*URLSession[[:space:]]*=[[:space:]]*\.shared' WhisperFlow/Integrations/OpenAI/OpenAITransport.swift >/dev/null; then
  echo "OpenAI transport must not use the shared URLSession" >&2
  failures=$((failures + 1))
fi

required_openai_session_policy=(
  'URLSessionConfiguration.ephemeral'
  'requestCachePolicy = .reloadIgnoringLocalCacheData'
  'urlCache = nil'
  'httpShouldSetCookies = false'
  'httpCookieAcceptPolicy = .never'
  'httpCookieStorage = nil'
  'urlCredentialStorage = nil'
)

for policy in "${required_openai_session_policy[@]}"; do
  if ! rg -F "$policy" WhisperFlow/Integrations/OpenAI/OpenAITransport.swift >/dev/null; then
    echo "OpenAI default session policy missing: $policy" >&2
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  exit 1
fi

echo "local-network static boundary: PASS"
