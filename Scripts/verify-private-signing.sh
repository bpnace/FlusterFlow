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
SIGNING_SUPPORT_DIR="${FLUSTERFLOW_SIGNING_SUPPORT_DIR:-$HOME/Library/Application Support/FlusterFlow/PrivateSigning}"
KEYCHAIN="${FLUSTERFLOW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/FlusterFlowSigning.keychain-db}"
PASSWORD_FILE="${FLUSTERFLOW_SIGNING_PASSWORD_FILE:-$SIGNING_SUPPORT_DIR/keychain-password}"
IDENTITY="${FLUSTERFLOW_CODE_SIGN_IDENTITY:-}"
MODE="verify"
TEMP_ROOT=""
VERIFIED_REQUIREMENT=""
VERIFIED_GATEKEEPER=""
VERIFIED_IDENTITY_CLASS=""
VERIFICATION_FAILURE=""
RELEASE_BUILD_COUNT=0

emit_prerequisite_status() {
  local status="$1"
  local reason="$2"
  printf '{"schemaVersion":1,"gate":"G9","mode":"prerequisites","status":"%s","reason":"%s","mutated":false}\n' \
    "$status" "$reason"
}

emit_failure() {
  local reason="$1"
  printf '{"schemaVersion":1,"gate":"G9","mode":"verification","status":"failed","reason":"%s","releaseBuilds":%s}\n' \
    "$reason" "$RELEASE_BUILD_COUNT"
}

usage() {
  cat <<'EOF'
Usage:
  verify-private-signing.sh --check-prerequisites [--identity <40-hex-fingerprint>]
  verify-private-signing.sh --identity <40-hex-fingerprint>

Instead of --identity, set FLUSTERFLOW_CODE_SIGN_IDENTITY to the same 40-character
SHA-1 fingerprint reported for an already installed valid code-signing identity.
The identity value is validated but never printed.
EOF
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ]; then
    case "$TEMP_ROOT" in
      /tmp/flusterflow-private-signing.*)
        /bin/rm -rf "$TEMP_ROOT"
        ;;
    esac
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-prerequisites)
      MODE="prerequisites"
      shift
      ;;
    --identity)
      if [ "$#" -lt 2 ]; then
        emit_prerequisite_status "failed" "identity_argument_missing"
        exit 1
      fi
      IDENTITY="$2"
      shift 2
      ;;
    --identity=*)
      IDENTITY="${1#--identity=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      emit_prerequisite_status "failed" "unsupported_argument"
      exit 1
      ;;
  esac
done

for tool in /usr/bin/xcodebuild /usr/bin/codesign /usr/bin/security /usr/sbin/spctl /usr/bin/plutil /usr/bin/cmp /usr/libexec/PlistBuddy; do
  if [ ! -x "$tool" ]; then
    emit_prerequisite_status "failed" "required_tool_missing"
    exit 1
  fi
done

if [ ! -f "$PROJECT/project.pbxproj" ] || \
   [ ! -f "$PROJECT/xcshareddata/xcschemes/$SCHEME.xcscheme" ] || \
   [ ! -f "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ] || \
   [ ! -f "$EXPECTED_ENTITLEMENTS" ]; then
  emit_prerequisite_status "failed" "project_contract_missing"
  exit 1
fi

if [ -f "$KEYCHAIN" ] && [ -f "$PASSWORD_FILE" ]; then
  IFS= read -r KEYCHAIN_PASSWORD <"$PASSWORD_FILE"
  if [ -z "${KEYCHAIN_PASSWORD:-}" ] || \
     ! /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    emit_prerequisite_status "blocked" "dedicated_signing_keychain_unlock_failed"
    exit 77
  fi

  KEYCHAINS=("$KEYCHAIN")
  while IFS= read -r existing; do
    existing="${existing#*\"}"
    existing="${existing%\"*}"
    if [ -n "$existing" ] && [ "$existing" != "$KEYCHAIN" ]; then
      KEYCHAINS+=("$existing")
    fi
  done < <(/usr/bin/security list-keychains -d user)
  /usr/bin/security list-keychains -d user -s "${KEYCHAINS[@]}"
fi

if [ -z "$IDENTITY" ]; then
  emit_prerequisite_status "blocked" "identity_required"
  exit 77
fi

if ! printf '%s' "$IDENTITY" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40}$'; then
  emit_prerequisite_status "failed" "identity_fingerprint_format_invalid"
  exit 1
fi

IDENTITY_UPPER="$(printf '%s' "$IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')"
if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
  /usr/bin/awk -v wanted="$IDENTITY_UPPER" '
    toupper($2) == wanted { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
  emit_prerequisite_status "blocked" "identity_not_valid"
  exit 77
fi

if [ "$MODE" = "prerequisites" ]; then
  emit_prerequisite_status "ready" "identity_valid"
  exit 0
fi

TEMP_ROOT="$(/usr/bin/mktemp -d /tmp/flusterflow-private-signing.XXXXXX)"
DERIVED_ONE="$TEMP_ROOT/derived-one"
DERIVED_TWO="$TEMP_ROOT/derived-two"
if ! /usr/bin/plutil -convert xml1 \
  -o "$TEMP_ROOT/expected-entitlements.xml" \
  "$EXPECTED_ENTITLEMENTS" >/dev/null 2>&1; then
  emit_failure "expected_entitlements_invalid"
  exit 1
fi

build_release() {
  local derived_data="$1"
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    -skipPackageUpdates \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build >/dev/null 2>&1
}

if ! build_release "$DERIVED_ONE"; then
  emit_failure "release_build_one_failed"
  exit 1
fi
RELEASE_BUILD_COUNT=1
if ! build_release "$DERIVED_TWO"; then
  emit_failure "release_build_two_failed"
  exit 1
fi
RELEASE_BUILD_COUNT=2

APP_ONE="$DERIVED_ONE/Build/Products/Release/FlusterFlow.app"
APP_TWO="$DERIVED_TWO/Build/Products/Release/FlusterFlow.app"

verify_app() {
  local app="$1"
  local entitlement_raw="$2"
  local entitlement_normalized="$3"
  local bundle_id
  local signature_metadata
  local requirement_output
  local authority_count

  VERIFICATION_FAILURE=""
  VERIFIED_REQUIREMENT=""
  VERIFIED_GATEKEEPER=""
  VERIFIED_IDENTITY_CLASS=""

  if [ ! -d "$app" ] || [ ! -f "$app/Contents/Info.plist" ]; then
    VERIFICATION_FAILURE="signed_app_missing"
    return 1
  fi

  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
    VERIFICATION_FAILURE="bundle_identifier_mismatch"
    return 1
  fi

  if ! /usr/bin/codesign --verify --deep --strict --verbose=0 "$app" >/dev/null 2>&1; then
    VERIFICATION_FAILURE="strict_signature_verification_failed"
    return 1
  fi

  signature_metadata="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1 || true)"
  if ! printf '%s\n' "$signature_metadata" | /usr/bin/grep -Eq 'flags=.*runtime'; then
    VERIFICATION_FAILURE="hardened_runtime_missing"
    return 1
  fi
  if printf '%s\n' "$signature_metadata" | /usr/bin/grep -Eq '^Signature=adhoc$'; then
    VERIFICATION_FAILURE="ad_hoc_signature_rejected"
    return 1
  fi
  authority_count="$(printf '%s\n' "$signature_metadata" | /usr/bin/awk '/^Authority=/{ count++ } END { print count + 0 }')"
  if [ "$authority_count" -eq 0 ]; then
    VERIFICATION_FAILURE="signing_authority_missing"
    return 1
  fi
  if [ "$authority_count" -eq 1 ]; then
    VERIFIED_IDENTITY_CLASS="local_self_signed"
  else
    VERIFIED_IDENTITY_CLASS="chained"
  fi

  requirement_output="$(/usr/bin/codesign -d -r- "$app" 2>&1 || true)"
  VERIFIED_REQUIREMENT="$(printf '%s\n' "$requirement_output" | /usr/bin/sed -n 's/^designated => //p')"
  if [ -z "$VERIFIED_REQUIREMENT" ]; then
    VERIFICATION_FAILURE="designated_requirement_missing"
    return 1
  fi

  if ! /usr/bin/codesign -d --entitlements :- "$app" >"$entitlement_raw" 2>/dev/null; then
    VERIFICATION_FAILURE="entitlements_extraction_failed"
    return 1
  fi
  if [ ! -s "$entitlement_raw" ]; then
    VERIFICATION_FAILURE="required_entitlement_missing"
    return 1
  fi
  if ! /usr/bin/plutil -convert xml1 -o "$entitlement_normalized" "$entitlement_raw" >/dev/null 2>&1; then
    VERIFICATION_FAILURE="entitlements_invalid"
    return 1
  fi
  if ! /usr/bin/cmp -s "$TEMP_ROOT/expected-entitlements.xml" "$entitlement_normalized"; then
    VERIFICATION_FAILURE="unexpected_entitlement"
    return 1
  fi

  if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
    VERIFIED_GATEKEEPER="accepted"
  else
    VERIFIED_GATEKEEPER="rejected_local_self_signed_boundary"
  fi
}

if ! verify_app "$APP_ONE" "$TEMP_ROOT/entitlements-one.raw" "$TEMP_ROOT/entitlements-one.xml"; then
  emit_failure "$VERIFICATION_FAILURE"
  exit 1
fi
REQUIREMENT_ONE="$VERIFIED_REQUIREMENT"
GATEKEEPER_ONE="$VERIFIED_GATEKEEPER"
IDENTITY_CLASS_ONE="$VERIFIED_IDENTITY_CLASS"

if ! verify_app "$APP_TWO" "$TEMP_ROOT/entitlements-two.raw" "$TEMP_ROOT/entitlements-two.xml"; then
  emit_failure "$VERIFICATION_FAILURE"
  exit 1
fi
REQUIREMENT_TWO="$VERIFIED_REQUIREMENT"
GATEKEEPER_TWO="$VERIFIED_GATEKEEPER"
IDENTITY_CLASS_TWO="$VERIFIED_IDENTITY_CLASS"

if [ "$REQUIREMENT_ONE" != "$REQUIREMENT_TWO" ]; then
  emit_failure "designated_requirement_mismatch"
  exit 1
fi
if ! /usr/bin/cmp -s "$TEMP_ROOT/entitlements-one.xml" "$TEMP_ROOT/entitlements-two.xml"; then
  emit_failure "entitlements_mismatch"
  exit 1
fi
if [ "$GATEKEEPER_ONE" != "$GATEKEEPER_TWO" ]; then
  emit_failure "gatekeeper_result_mismatch"
  exit 1
fi
if [ "$IDENTITY_CLASS_ONE" != "$IDENTITY_CLASS_TWO" ]; then
  emit_failure "identity_class_mismatch"
  exit 1
fi

if [ "$GATEKEEPER_ONE" = "rejected_local_self_signed_boundary" ]; then
  if [ "$IDENTITY_CLASS_ONE" != "local_self_signed" ]; then
    emit_failure "gatekeeper_rejected_nonlocal_identity"
    exit 1
  fi
  printf '%s\n' '{"schemaVersion":1,"gate":"G9","mode":"verification","status":"blocked","reason":"gatekeeper_local_self_signed_boundary","releaseBuilds":2,"bundleIdentifierMatch":true,"strictSignatureVerification":true,"hardenedRuntime":true,"entitlements":"audio_input_only","designatedRequirementMatch":true,"gatekeeper":"rejected_both","manualLaunchAndTCCRequired":true}'
  exit 77
fi

printf '{"schemaVersion":1,"gate":"G9","mode":"verification","status":"passed","releaseBuilds":2,"bundleIdentifierMatch":true,"strictSignatureVerification":true,"hardenedRuntime":true,"entitlements":"audio_input_only","designatedRequirementMatch":true,"identityClass":"%s","gatekeeper":"accepted_both","manualLaunchAndTCCRequired":true}\n' \
  "$IDENTITY_CLASS_ONE"
