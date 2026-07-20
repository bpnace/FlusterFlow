#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/WhisperFlow.xcodeproj"
SCHEME="WhisperFlow"
LABEL="${FLUSTERFLOW_LOCAL_SIGNING_LABEL:-FlusterFlow Private Signing}"
SIGNING_SUPPORT_DIR="${FLUSTERFLOW_SIGNING_SUPPORT_DIR:-$HOME/Library/Application Support/FlusterFlow/PrivateSigning}"
KEYCHAIN="${FLUSTERFLOW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/FlusterFlowSigning.keychain-db}"
PASSWORD_FILE="${FLUSTERFLOW_SIGNING_PASSWORD_FILE:-$SIGNING_SUPPORT_DIR/keychain-password}"
INSTALL_ROOT="$HOME/Applications"
INSTALL_APP="$INSTALL_ROOT/FlusterFlow.app"
BUILD_ROOT=""
STAGING_ROOT=""

cleanup() {
  local status=$?
  trap - EXIT
  for directory in "$BUILD_ROOT" "$STAGING_ROOT"; do
    if [ -n "$directory" ] && [ -d "$directory" ]; then
      case "$directory" in
        /tmp/flusterflow-private-build.*|"$INSTALL_ROOT"/.flusterflow-install.*)
          /bin/rm -rf "$directory"
          ;;
      esac
    fi
  done
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$KEYCHAIN" ] || [ ! -f "$PASSWORD_FILE" ]; then
  printf '{"schemaVersion":1,"status":"blocked","reason":"dedicated_signing_keychain_missing"}\n'
  exit 77
fi

IFS= read -r KEYCHAIN_PASSWORD <"$PASSWORD_FILE"
if [ -z "${KEYCHAIN_PASSWORD:-}" ] || \
   ! /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
  printf '{"schemaVersion":1,"status":"blocked","reason":"dedicated_signing_keychain_unlock_failed"}\n'
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

BUILT_APP="$BUILD_ROOT/Build/Products/Release/FlusterFlow.app"
if [ ! -d "$BUILT_APP" ]; then
  printf '{"schemaVersion":1,"status":"failed","reason":"built_app_missing"}\n'
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=0 "$BUILT_APP"

/bin/mkdir -p "$INSTALL_ROOT"
STAGING_ROOT="$(/usr/bin/mktemp -d "$INSTALL_ROOT/.flusterflow-install.XXXXXX")"
/usr/bin/ditto "$BUILT_APP" "$STAGING_ROOT/FlusterFlow.app"

/usr/bin/pkill -TERM -x FlusterFlow 2>/dev/null || true
for _ in 1 2 3 4 5; do
  if ! /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 1
done

PREVIOUS_APP="$STAGING_ROOT/previous-install.bundle-backup"
if [ -d "$INSTALL_APP" ]; then
  /bin/mv "$INSTALL_APP" "$PREVIOUS_APP"
fi
if ! /bin/mv "$STAGING_ROOT/FlusterFlow.app" "$INSTALL_APP"; then
  if [ -d "$PREVIOUS_APP" ]; then
    /bin/mv "$PREVIOUS_APP" "$INSTALL_APP"
  fi
  printf '{"schemaVersion":1,"status":"failed","reason":"atomic_install_failed"}\n'
  exit 1
fi
if ! /usr/bin/open -n "$INSTALL_APP"; then
  printf '{"schemaVersion":1,"status":"failed","reason":"installed_app_launch_failed"}\n'
  exit 1
fi

for _ in 1 2 3 4 5; do
  if /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 1
done
if ! /usr/bin/pgrep -x FlusterFlow >/dev/null 2>&1; then
  printf '{"schemaVersion":1,"status":"failed","reason":"installed_app_process_missing"}\n'
  exit 1
fi

printf '{"schemaVersion":1,"status":"installed","path":"%s"}\n' "$INSTALL_APP"
