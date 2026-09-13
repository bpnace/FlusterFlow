#!/usr/bin/env bash
set +x
set -euo pipefail
export LC_ALL=C
umask 077

LABEL="${FLUSTERFLOW_LOCAL_SIGNING_LABEL:-FlusterFlow Private Signing}"
SIGNING_SUPPORT_DIR="${FLUSTERFLOW_SIGNING_SUPPORT_DIR:-$HOME/Library/Application Support/FlusterFlow/PrivateSigning}"
KEYCHAIN="${FLUSTERFLOW_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/FlusterFlowSigning.keychain-db}"
PASSWORD_FILE="${FLUSTERFLOW_SIGNING_PASSWORD_FILE:-$SIGNING_SUPPORT_DIR/keychain-password}"
TEMP_ROOT=""

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ]; then
    case "$TEMP_ROOT" in
      /tmp/flusterflow-local-signing.*)
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

find_identity() {
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | \
    /usr/bin/awk -v label="$LABEL" 'index($0, "\"" label "\"") { print $2; exit }'
}

for tool in /usr/bin/codesign /usr/bin/openssl /usr/bin/security /usr/bin/uuidgen /usr/bin/mktemp; do
  if [ ! -x "$tool" ]; then
    printf '{"schemaVersion":1,"status":"failed","reason":"required_tool_missing"}\n'
    exit 1
  fi
done

ensure_keychain_search_list() {
  local existing
  local keychains=("$KEYCHAIN")

  while IFS= read -r existing; do
    existing="${existing#*\"}"
    existing="${existing%\"*}"
    if [ -n "$existing" ] && [ "$existing" != "$KEYCHAIN" ]; then
      keychains+=("$existing")
    fi
  done < <(/usr/bin/security list-keychains -d user)

  /usr/bin/security list-keychains -d user -s "${keychains[@]}"
}

if [ -e "$KEYCHAIN" ] && [ ! -f "$PASSWORD_FILE" ]; then
  printf '{"schemaVersion":1,"status":"failed","reason":"dedicated_keychain_password_missing"}\n'
  exit 1
fi

/bin/mkdir -p "$SIGNING_SUPPORT_DIR" "$(/usr/bin/dirname "$KEYCHAIN")"
/bin/chmod 700 "$SIGNING_SUPPORT_DIR"

if [ ! -f "$PASSWORD_FILE" ]; then
  KEYCHAIN_PASSWORD="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
  printf '%s\n' "$KEYCHAIN_PASSWORD" >"$PASSWORD_FILE"
  /bin/chmod 600 "$PASSWORD_FILE"
else
  IFS= read -r KEYCHAIN_PASSWORD <"$PASSWORD_FILE"
fi

if [ -z "${KEYCHAIN_PASSWORD:-}" ]; then
  printf '{"schemaVersion":1,"status":"failed","reason":"dedicated_keychain_password_empty"}\n'
  exit 1
fi

if [ ! -e "$KEYCHAIN" ]; then
  /usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  /bin/chmod 600 "$KEYCHAIN"
fi

if ! /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"; then
  printf '{"schemaVersion":1,"status":"failed","reason":"dedicated_keychain_unlock_failed"}\n'
  exit 1
fi
/usr/bin/security set-keychain-settings -lut 21600 "$KEYCHAIN"
ensure_keychain_search_list

verify_identity_can_sign() {
  local identity="$1"
  local probe

  if [ -z "$TEMP_ROOT" ]; then
    TEMP_ROOT="$(/usr/bin/mktemp -d /tmp/flusterflow-local-signing.XXXXXX)"
  fi
  probe="$TEMP_ROOT/signing-probe"
  /bin/cp /bin/echo "$probe"
  /usr/bin/codesign --force --sign "$identity" --timestamp=none "$probe" >/dev/null 2>&1 &&
    /usr/bin/codesign --verify --strict --verbose=0 "$probe" >/dev/null 2>&1
}

configure_codesign_access() {
  /usr/bin/security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" \
    >/dev/null
}

EXISTING_IDENTITY="$(find_identity)"
if [ -n "$EXISTING_IDENTITY" ]; then
  if ! configure_codesign_access; then
    printf '{"schemaVersion":1,"status":"failed","reason":"existing_identity_access_configuration_failed"}\n'
    exit 1
  fi
  if verify_identity_can_sign "$EXISTING_IDENTITY"; then
    printf '{"schemaVersion":1,"status":"ready","created":false,"label":"%s","keychain":"dedicated"}\n' "$LABEL"
    exit 0
  fi
  printf '{"schemaVersion":1,"status":"failed","reason":"existing_identity_private_key_unusable"}\n'
  exit 1
fi

if [ -z "$TEMP_ROOT" ]; then
  TEMP_ROOT="$(/usr/bin/mktemp -d /tmp/flusterflow-local-signing.XXXXXX)"
fi
PRIVATE_KEY="$TEMP_ROOT/private-key.pem"
CERTIFICATE="$TEMP_ROOT/certificate.pem"
IDENTITY_ARCHIVE="$TEMP_ROOT/identity.p12"
ARCHIVE_PASSWORD="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"

/usr/bin/openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days 3650 \
  -nodes \
  -subj "/CN=$LABEL/O=FlusterFlow Local Development/OU=Private Signing" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE" \
  >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
  -export \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -name "$LABEL" \
  -passout "pass:$ARCHIVE_PASSWORD" \
  -out "$IDENTITY_ARCHIVE" \
  >/dev/null 2>&1

/usr/bin/security import "$IDENTITY_ARCHIVE" \
  -k "$KEYCHAIN" \
  -P "$ARCHIVE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERTIFICATE" \
  >/dev/null

if ! configure_codesign_access; then
  printf '{"schemaVersion":1,"status":"failed","reason":"created_identity_access_configuration_failed"}\n'
  exit 1
fi

if [ -z "$(find_identity)" ]; then
  printf '{"schemaVersion":1,"status":"failed","reason":"identity_not_valid_after_import"}\n'
  exit 1
fi

CREATED_IDENTITY="$(find_identity)"
if ! verify_identity_can_sign "$CREATED_IDENTITY"; then
  printf '{"schemaVersion":1,"status":"failed","reason":"created_identity_private_key_unusable"}\n'
  exit 1
fi

printf '{"schemaVersion":1,"status":"ready","created":true,"label":"%s","keychain":"dedicated"}\n' "$LABEL"
