#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/Scripts/verify-private-signing.sh"
INSTALL="$ROOT/Scripts/build-install-private.sh"
FAKE_HASH="0123456789abcdef0123456789abcdef01234567"

expect_failure() {
  local expected_reason="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ] || ! printf '%s\n' "$output" | /usr/bin/grep -Fq "\"reason\":\"$expected_reason\""; then
    printf 'expected failure reason %s, got status=%s output=%s\n' "$expected_reason" "$status" "$output" >&2
    exit 1
  fi
}

/bin/bash -n "$VERIFY"
/bin/bash -n "$INSTALL"

expect_failure "artifact_export_path_invalid" \
  /bin/bash "$VERIFY" --identity "$FAKE_HASH" --export-app relative/FlusterFlow.app
expect_failure "artifact_export_not_available_in_prerequisite_mode" \
  /bin/bash "$VERIFY" --check-prerequisites --identity "$FAKE_HASH" --export-app /tmp/FlusterFlow.app
expect_failure "verified_app_path_invalid" \
  /bin/bash "$INSTALL" --verified-app relative/FlusterFlow.app --expected-cdhash "$FAKE_HASH"
expect_failure "verified_app_missing_or_symlinked" \
  /bin/bash "$INSTALL" --verified-app /tmp/flusterflow-chain-test-missing.app --expected-cdhash "$FAKE_HASH"
expect_failure "expected_cdhash_requires_verified_app" \
  /bin/bash "$INSTALL" --expected-cdhash "$FAKE_HASH"

assert_source_contract() {
  local pattern="$1"
  if ! /usr/bin/grep -Fq "$pattern" "$INSTALL"; then
    printf 'missing installer source contract: %s\n' "$pattern" >&2
    exit 1
  fi
}

assert_file_source_contract() {
  local file="$1"
  local pattern="$2"
  if ! /usr/bin/grep -Fq "$pattern" "$file"; then
    printf 'missing source contract in %s: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

line_of_in() {
  local file="$1"
  local pattern="$2"
  /usr/bin/grep -nF "$pattern" "$file" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

line_of() {
  /usr/bin/grep -nF "$1" "$INSTALL" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

assert_source_contract 'emit_status "failed" "existing_app_process_would_not_terminate"'
assert_source_contract 'emit_status "failed" "installed_app_launch_failed_install_rolled_back"'
assert_source_contract 'emit_status "failed" "installed_app_process_missing_install_rolled_back"'
assert_source_contract 'emit_status "failed" "installed_app_process_path_mismatch_install_rolled_back"'
assert_source_contract 'executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"'
assert_source_contract 'if [ "$executable" = "$expected_executable" ]; then'
assert_source_contract 'if [ "$INSTALL_CONFIRMED" != true ] && [ -n "$STAGING_ROOT" ]; then'
assert_source_contract '[ -n "$PREVIOUS_APP" ] && [ -d "$PREVIOUS_APP" ]'
assert_source_contract '[ "$HAD_PREVIOUS_INSTALL" = false ]'
assert_source_contract '[ ! -d "$STAGED_APP" ]'
assert_source_contract 'INSTALL_TRANSACTION_STARTED=true'
assert_source_contract 'INSTALL_REPLACED=true'
assert_source_contract 'INSTALL_CONFIRMED=true'

for signing_script in "$VERIFY" "$INSTALL"; do
  assert_file_source_contract "$signing_script" 'if ! USER_KEYCHAIN_LIST_OUTPUT="$(/usr/bin/security list-keychains -d user)"; then'
  assert_file_source_contract "$signing_script" 'done <<<"$USER_KEYCHAIN_LIST_OUTPUT"'
  assert_file_source_contract "$signing_script" 'KEYCHAIN_SEARCH_LIST_CHANGED=true'

  SNAPSHOT_LINE="$(line_of_in "$signing_script" 'if ! USER_KEYCHAIN_LIST_OUTPUT="$(/usr/bin/security list-keychains -d user)"; then')"
  CLEANUP_GUARD_LINE="$(line_of_in "$signing_script" 'KEYCHAIN_SEARCH_LIST_CHANGED=true')"
  SEARCH_LIST_MUTATION_LINE="$(line_of_in "$signing_script" '  /usr/bin/security list-keychains -d user -s "${KEYCHAINS[@]}"')"
  if [ "$SNAPSHOT_LINE" -ge "$CLEANUP_GUARD_LINE" ] || \
     [ "$CLEANUP_GUARD_LINE" -ge "$SEARCH_LIST_MUTATION_LINE" ]; then
    printf '%s\n' 'keychain snapshot must succeed before the cleanup guard is armed and the search list is mutated' >&2
    exit 1
  fi
done

PROCESS_GUARD_LINE="$(line_of 'existing_app_process_would_not_terminate')"
REPLACEMENT_LINE="$(line_of 'PREVIOUS_APP="$STAGING_ROOT/previous-install.bundle-backup"')"
if [ "$PROCESS_GUARD_LINE" -ge "$REPLACEMENT_LINE" ]; then
  printf '%s\n' 'existing-process guard must run before bundle replacement' >&2
  exit 1
fi

ROLLBACK_CALL_COUNT="$(/usr/bin/grep -cF 'if ! rollback_install; then' "$INSTALL")"
if [ "$ROLLBACK_CALL_COUNT" -ne 5 ]; then
  printf 'expected five rollback guards including exit cleanup, got %s\n' "$ROLLBACK_CALL_COUNT" >&2
  exit 1
fi

REPLACED_LINE="$(line_of 'INSTALL_REPLACED=true')"
TRANSACTION_LINE="$(line_of 'INSTALL_TRANSACTION_STARTED=true')"
PREVIOUS_MOVE_LINE="$(line_of '/bin/mv "$INSTALL_APP" "$PREVIOUS_APP"')"
INSTALL_MOVE_LINE="$(line_of 'if ! /bin/mv "$STAGING_ROOT/FlusterFlow.app" "$INSTALL_APP"; then')"
CONFIRMED_LINE="$(line_of 'INSTALL_CONFIRMED=true')"
SUCCESS_LINE="$(line_of 'printf '\''{"schemaVersion":1,"status":"installed"')"
if [ "$TRANSACTION_LINE" -ge "$PREVIOUS_MOVE_LINE" ] || \
   [ "$REPLACED_LINE" -ge "$INSTALL_MOVE_LINE" ] || \
   [ "$CONFIRMED_LINE" -ge "$SUCCESS_LINE" ]; then
  printf '%s\n' 'install transaction state must bracket replacement and success emission' >&2
  exit 1
fi

NONLOCAL_REJECTION_LINE="$(/usr/bin/grep -nF 'emit_failure "gatekeeper_rejected_nonlocal_identity"' "$VERIFY" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
EXPORT_FINALIZE_LINE="$(/usr/bin/grep -nF 'if ! /bin/mv "$EXPORTED_STAGING_APP" "$EXPORT_APP"; then' "$VERIFY" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
if [ -z "$NONLOCAL_REJECTION_LINE" ] || [ -z "$EXPORT_FINALIZE_LINE" ] || \
   [ "$NONLOCAL_REJECTION_LINE" -ge "$EXPORT_FINALIZE_LINE" ]; then
  printf '%s\n' 'nonlocal Gatekeeper rejection must run before artifact export finalization' >&2
  exit 1
fi

TRANSACTION_TEST_ROOT="$(/usr/bin/mktemp -d /tmp/flusterflow-install-transaction-test.XXXXXX)"
transaction_cleanup() {
  case "$TRANSACTION_TEST_ROOT" in
    /tmp/flusterflow-install-transaction-test.*)
      /bin/rm -rf "$TRANSACTION_TEST_ROOT"
      ;;
  esac
}
trap transaction_cleanup EXIT

set +e
(
  export HOME="$TRANSACTION_TEST_ROOT/home"
  source "$INSTALL"
  INSTALL_ROOT="$HOME/Applications"
  INSTALL_APP="$INSTALL_ROOT/FlusterFlow.app"
  STAGING_ROOT="$INSTALL_ROOT/.flusterflow-install.signal-test"
  STAGED_APP="$STAGING_ROOT/FlusterFlow.app"
  PREVIOUS_APP="$STAGING_ROOT/previous-install.bundle-backup"
  /bin/mkdir -p "$INSTALL_APP" "$STAGED_APP"
  printf '%s\n' original >"$INSTALL_APP/original.marker"
  HAD_PREVIOUS_INSTALL=true
  INSTALL_TRANSACTION_STARTED=true
  /bin/mv "$INSTALL_APP" "$PREVIOUS_APP"
  INSTALL_REPLACED=false
  INSTALL_CONFIRMED=false
  trap cleanup EXIT
  exit 143
)
SIGNAL_STATUS=$?
set -e
if [ "$SIGNAL_STATUS" -ne 143 ] || \
   [ ! -f "$TRANSACTION_TEST_ROOT/home/Applications/FlusterFlow.app/original.marker" ] || \
   [ -d "$TRANSACTION_TEST_ROOT/home/Applications/.flusterflow-install.signal-test" ]; then
  printf '%s\n' 'signal after backup move must restore the original app and clean staging' >&2
  exit 1
fi

printf '%s\n' 'Verified artifact chain parser: PASS'
