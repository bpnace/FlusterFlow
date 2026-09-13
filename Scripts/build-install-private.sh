#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/WhisperFlow.xcodeproj"
SCHEME="WhisperFlow"
EXPECTED_BUNDLE_ID="com.flusterflow.private"
EXPECTED_ENTITLEMENTS="$ROOT/WhisperFlow/WhisperFlow.entitlements"
LABEL="${FLUSTERFLOW_LOCAL_SIGNING_LABEL:-FlusterFlow Private Signing}"
SIGNING_SUPPORT_DIR="${FLUSTERFLOW_SIGNING_SUPPORT_DIR:-$HOME/Library/Application Support/FlusterFlow/PrivateSigning}"
KEYCHAIN="${FLUSTERFLOW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/FlusterFlowSigning.keychain-db}"
PASSWORD_FILE="${FLUSTERFLOW_SIGNING_PASSWORD_FILE:-$SIGNING_SUPPORT_DIR/keychain-password}"
INSTALL_ROOT="$HOME/Applications"
INSTALL_APP="$INSTALL_ROOT/FlusterFlow.app"
BUILD_ROOT=""
STAGING_ROOT=""
PRESERVE_STAGING=false
INSTALL_REPLACED=false
INSTALL_CONFIRMED=false
INSTALL_TRANSACTION_STARTED=false
HAD_PREVIOUS_INSTALL=false
PREVIOUS_APP=""
STAGED_APP=""
VERIFIED_APP=""
EXPECTED_CDHASH=""
MODE="build"
ORIGINAL_USER_KEYCHAINS=()
KEYCHAIN_SEARCH_LIST_CHANGED=false

emit_status() {
  local status="$1"
  local reason="$2"
  printf '{"schemaVersion":1,"status":"%s","reason":"%s"}\n' "$status" "$reason"
}

usage() {
  cat <<'EOF'
Usage:
  build-install-private.sh
  build-install-private.sh --verified-app <absolute-path.app> --expected-cdhash <hex>

The default mode builds and installs as before. Artifact mode does not rebuild;
it stages and re-verifies the exact exported app identified by its CDHash.
EOF
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$KEYCHAIN_SEARCH_LIST_CHANGED" = true ]; then
    if ! /usr/bin/security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null 2>&1; then
      if [ "$status" -eq 0 ]; then
        status=1
      fi
    fi
  fi
  if [ "$INSTALL_CONFIRMED" != true ] && [ -n "$STAGING_ROOT" ]; then
    if { [ -n "$PREVIOUS_APP" ] && [ -d "$PREVIOUS_APP" ]; } || \
       { [ "$INSTALL_TRANSACTION_STARTED" = true ] && \
         [ "$HAD_PREVIOUS_INSTALL" = false ] && \
         [ -d "$INSTALL_APP" ] && [ ! -d "$STAGED_APP" ]; } || \
       [ "$INSTALL_REPLACED" = true ]; then
      if ! rollback_install; then
        PRESERVE_STAGING=true
      fi
    fi
  fi
  for directory in "$BUILD_ROOT" "$STAGING_ROOT"; do
    if [ -n "$directory" ] && [ -d "$directory" ]; then
      if [ "$directory" = "$STAGING_ROOT" ] && [ "$PRESERVE_STAGING" = true ]; then
        continue
      fi
      case "$directory" in
        /tmp/flusterflow-private-build.*|"$INSTALL_ROOT"/.flusterflow-install.*)
          /bin/rm -rf "$directory"
          ;;
      esac
    fi
  done
  exit "$status"
}

rollback_install() {
  local failed_app="$STAGING_ROOT/failed-install.bundle"

  if [ -d "$INSTALL_APP" ]; then
    if [ -e "$failed_app" ] || ! /bin/mv "$INSTALL_APP" "$failed_app"; then
      PRESERVE_STAGING=true
      return 1
    fi
  fi
  if [ -n "$PREVIOUS_APP" ] && [ -d "$PREVIOUS_APP" ] && \
     ! /bin/mv "$PREVIOUS_APP" "$INSTALL_APP"; then
    PRESERVE_STAGING=true
    return 1
  fi
  INSTALL_REPLACED=false
}

find_installed_process() {
  local expected_executable="$INSTALL_APP/Contents/MacOS/FlusterFlow"
  local pid
  local executable

  INSTALLED_PROCESS_PID=""
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [ "$executable" = "$expected_executable" ]; then
      INSTALLED_PROCESS_PID="$pid"
      return 0
    fi
  done < <(/usr/bin/pgrep -x FlusterFlow 2>/dev/null || true)
  return 1
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verified-app)
      if [ "$#" -lt 2 ]; then
        emit_status "failed" "verified_app_argument_missing"
        exit 1
      fi
      VERIFIED_APP="$2"
      MODE="artifact"
      shift 2
      ;;
    --verified-app=*)
      VERIFIED_APP="${1#--verified-app=}"
      MODE="artifact"
      shift
      ;;
    --expected-cdhash)
      if [ "$#" -lt 2 ]; then
        emit_status "failed" "expected_cdhash_argument_missing"
        exit 1
      fi
      EXPECTED_CDHASH="$2"
      shift 2
      ;;
    --expected-cdhash=*)
      EXPECTED_CDHASH="${1#--expected-cdhash=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      emit_status "failed" "unsupported_argument"
      exit 1
      ;;
  esac
done

if [ "$MODE" = "artifact" ]; then
  case "$VERIFIED_APP" in
    /*.app) ;;
    *)
      emit_status "failed" "verified_app_path_invalid"
      exit 1
      ;;
  esac
  if [ ! -d "$VERIFIED_APP" ] || [ -L "$VERIFIED_APP" ]; then
    emit_status "failed" "verified_app_missing_or_symlinked"
    exit 1
  fi
  if ! printf '%s' "$EXPECTED_CDHASH" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40,64}$'; then
    emit_status "failed" "expected_cdhash_invalid"
    exit 1
  fi
  EXPECTED_CDHASH="$(printf '%s' "$EXPECTED_CDHASH" | /usr/bin/tr '[:lower:]' '[:upper:]')"
elif [ -n "$EXPECTED_CDHASH" ]; then
  emit_status "failed" "expected_cdhash_requires_verified_app"
  exit 1
fi

for tool in /usr/bin/xcodebuild /usr/bin/codesign /usr/bin/security /usr/bin/plutil /usr/bin/cmp /usr/bin/ditto /usr/libexec/PlistBuddy; do
  if [ ! -x "$tool" ]; then
    emit_status "failed" "required_tool_missing"
    exit 1
  fi
done

if [ "$MODE" = "build" ] && { [ ! -f "$KEYCHAIN" ] || [ ! -f "$PASSWORD_FILE" ]; }; then
  printf '{"schemaVersion":1,"status":"blocked","reason":"dedicated_signing_keychain_missing"}\n'
  exit 77
fi

if [ "$MODE" = "build" ]; then
  IFS= read -r KEYCHAIN_PASSWORD <"$PASSWORD_FILE"
  if [ -z "${KEYCHAIN_PASSWORD:-}" ] || \
     ! /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    printf '{"schemaVersion":1,"status":"blocked","reason":"dedicated_signing_keychain_unlock_failed"}\n'
    exit 77
  fi

  if ! USER_KEYCHAIN_LIST_OUTPUT="$(/usr/bin/security list-keychains -d user)"; then
    emit_status "failed" "user_keychain_search_list_snapshot_failed"
    exit 1
  fi
  while IFS= read -r existing; do
    existing="${existing#*\"}"
    existing="${existing%\"*}"
    if [ -n "$existing" ]; then
      ORIGINAL_USER_KEYCHAINS+=("$existing")
    fi
  done <<<"$USER_KEYCHAIN_LIST_OUTPUT"

  KEYCHAINS=("$KEYCHAIN")
  for existing in "${ORIGINAL_USER_KEYCHAINS[@]}"; do
    if [ -n "$existing" ] && [ "$existing" != "$KEYCHAIN" ]; then
      KEYCHAINS+=("$existing")
    fi
  done
  KEYCHAIN_SEARCH_LIST_CHANGED=true
  /usr/bin/security list-keychains -d user -s "${KEYCHAINS[@]}"

  IDENTITY="$(/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | \
    /usr/bin/awk -v label="$LABEL" 'index($0, "\"" label "\"") { print $2; exit }')"
  if [ -z "$IDENTITY" ]; then
    printf '{"schemaVersion":1,"status":"blocked","reason":"local_signing_identity_missing"}\n'
    exit 77
  fi

  BUILD_ROOT="$(/usr/bin/mktemp -d /tmp/flusterflow-private-build.XXXXXX)"
  /usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_ROOT" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build >/dev/null

  CANDIDATE_APP="$BUILD_ROOT/Build/Products/Release/FlusterFlow.app"
  if [ ! -d "$CANDIDATE_APP" ]; then
    printf '{"schemaVersion":1,"status":"failed","reason":"built_app_missing"}\n'
    exit 1
  fi
else
  CANDIDATE_APP="$VERIFIED_APP"
fi

/bin/mkdir -p "$INSTALL_ROOT"
STAGING_ROOT="$(/usr/bin/mktemp -d "$INSTALL_ROOT/.flusterflow-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/FlusterFlow.app"
/usr/bin/ditto "$CANDIDATE_APP" "$STAGED_APP"

if ! /usr/bin/codesign --verify --deep --strict --verbose=0 "$STAGED_APP" >/dev/null 2>&1; then
  emit_status "failed" "strict_signature_verification_failed"
  exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
  emit_status "failed" "bundle_identifier_mismatch"
  exit 1
fi
SIGNATURE_METADATA="$(/usr/bin/codesign -d --verbose=4 "$STAGED_APP" 2>&1 || true)"
if ! printf '%s\n' "$SIGNATURE_METADATA" | /usr/bin/grep -Eq 'flags=.*runtime'; then
  emit_status "failed" "hardened_runtime_missing"
  exit 1
fi
if printf '%s\n' "$SIGNATURE_METADATA" | /usr/bin/grep -Eq '^Signature=adhoc$'; then
  emit_status "failed" "ad_hoc_signature_rejected"
  exit 1
fi
AUTHORITY_COUNT="$(printf '%s\n' "$SIGNATURE_METADATA" | /usr/bin/awk '/^Authority=/{ count++ } END { print count + 0 }')"
if [ "$AUTHORITY_COUNT" -eq 0 ]; then
  emit_status "failed" "signing_authority_missing"
  exit 1
fi
ACTUAL_CDHASH="$(printf '%s\n' "$SIGNATURE_METADATA" | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -n 1 | /usr/bin/tr '[:lower:]' '[:upper:]')"
if ! printf '%s' "$ACTUAL_CDHASH" | /usr/bin/grep -Eq '^[0-9A-F]{40,64}$'; then
  emit_status "failed" "code_directory_hash_missing"
  exit 1
fi
if [ "$MODE" = "artifact" ] && [ "$ACTUAL_CDHASH" != "$EXPECTED_CDHASH" ]; then
  emit_status "failed" "code_directory_hash_mismatch"
  exit 1
fi
DESIGNATED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$STAGED_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [ -z "$DESIGNATED_REQUIREMENT" ]; then
  emit_status "failed" "designated_requirement_missing"
  exit 1
fi
if ! /usr/bin/plutil -convert xml1 -o "$STAGING_ROOT/expected-entitlements.xml" "$EXPECTED_ENTITLEMENTS" >/dev/null 2>&1 || \
   ! /usr/bin/codesign -d --entitlements :- "$STAGED_APP" >"$STAGING_ROOT/actual-entitlements.raw" 2>/dev/null || \
   ! /usr/bin/plutil -convert xml1 -o "$STAGING_ROOT/actual-entitlements.xml" "$STAGING_ROOT/actual-entitlements.raw" >/dev/null 2>&1; then
  emit_status "failed" "entitlements_verification_failed"
  exit 1
fi
if ! /usr/bin/cmp -s "$STAGING_ROOT/expected-entitlements.xml" "$STAGING_ROOT/actual-entitlements.xml"; then
  emit_status "failed" "unexpected_entitlement"
  exit 1
fi

/usr/bin/pkill -TERM -x FlusterFlow 2>/dev/null || true
for _ in 1 2 3 4 5; do
  if ! /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 1
done
if /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
  emit_status "failed" "existing_app_process_would_not_terminate"
  exit 1
fi

PREVIOUS_APP="$STAGING_ROOT/previous-install.bundle-backup"
if [ -d "$INSTALL_APP" ]; then
  HAD_PREVIOUS_INSTALL=true
fi
INSTALL_TRANSACTION_STARTED=true
if [ "$HAD_PREVIOUS_INSTALL" = true ]; then
  /bin/mv "$INSTALL_APP" "$PREVIOUS_APP"
fi
INSTALL_REPLACED=true
if ! /bin/mv "$STAGING_ROOT/FlusterFlow.app" "$INSTALL_APP"; then
  if ! rollback_install; then
    emit_status "failed" "atomic_install_failed_and_rollback_failed"
    exit 1
  fi
  emit_status "failed" "atomic_install_failed_install_rolled_back"
  exit 1
fi
if ! /usr/bin/open -n "$INSTALL_APP"; then
  if ! rollback_install; then
    emit_status "failed" "installed_app_launch_failed_and_rollback_failed"
    exit 1
  fi
  emit_status "failed" "installed_app_launch_failed_install_rolled_back"
  exit 1
fi

for _ in 1 2 3 4 5; do
  if find_installed_process; then
    break
  fi
  /bin/sleep 1
done
if ! find_installed_process; then
  if /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
    /usr/bin/pkill -TERM -x FlusterFlow 2>/dev/null || true
    if ! rollback_install; then
      emit_status "failed" "installed_app_process_path_mismatch_and_rollback_failed"
      exit 1
    fi
    emit_status "failed" "installed_app_process_path_mismatch_install_rolled_back"
    exit 1
  fi
  if ! rollback_install; then
    emit_status "failed" "installed_app_process_missing_and_rollback_failed"
    exit 1
  fi
  emit_status "failed" "installed_app_process_missing_install_rolled_back"
  exit 1
fi

INSTALL_CONFIRMED=true
printf '{"schemaVersion":1,"status":"installed","source":"%s","bundleIdentifierMatch":true,"strictSignatureVerification":true,"hardenedRuntime":true,"entitlements":"audio_input_only","designatedRequirementPresent":true,"cdHash":"%s"}\n' \
  "$MODE" "$ACTUAL_CDHASH"
