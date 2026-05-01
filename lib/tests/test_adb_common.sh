#!/usr/bin/env bash
# Unit tests for adb_common.sh helper functions (no real device needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

_t_pass() {
    PASS=$((PASS + 1))
    printf '  OK: %s\n' "$1"
}

_t_fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "$1"
}

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

export XDG_STATE_HOME="${TEST_TMPDIR}/state"
mkdir -p "${XDG_STATE_HOME}"

source "${SCRIPT_DIR}/../adb_common.sh"

ADB_MOCK_MODEL=$'Pixel "7";$(rm -rf /)`danger`\nline2'
ADB_MOCK_FINGERPRINT='google/pixel:14/UP1A.231005.007/$evil;`cmd`'

adb() {
    if [[ "$#" -eq 1 && "$1" == "devices" ]]; then
        printf 'List of devices attached\nSERIAL123\tdevice\n'
        return 0
    fi

    if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "getprop" && "$5" == "ro.product.model" ]]; then
        printf '%s\r\n' "${ADB_MOCK_MODEL}"
        return 0
    fi

    if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "getprop" && "$5" == "ro.build.fingerprint" ]]; then
        printf '%s\r\n' "${ADB_MOCK_FINGERPRINT}"
        return 0
    fi

    if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "su" && "$5" == "--mount-master" && "$6" == "-c" && "$7" == "echo ok" ]]; then
        printf 'ok\n'
        return 0
    fi

    printf 'Unexpected adb invocation:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 1
}

run_test() {
    local name="$1"
    shift

    if "$@"; then
        _t_pass "${name}"
    else
        _t_fail "${name}"
    fi
}

test_box_does_not_crash() {
    _box "Test title" "line 1" "line 2" >/dev/null 2>&1
}

test_check_cooldown_zero_allows() {
    LAST_RUN_DIR="${TEST_TMPDIR}/cooldown-zero"
    adb_check_cooldown 0 "test_marker"
}

test_check_cooldown_blocks_when_marker_fresh() {
    LAST_RUN_DIR="${TEST_TMPDIR}/cooldown-block"
    mkdir -p "${LAST_RUN_DIR}"
    date +%s >"${LAST_RUN_DIR}/fresh_marker"

    if adb_check_cooldown 9999 "fresh_marker"; then
        return 1
    fi

    return 0
}

test_mark_last_run_creates_marker() {
    LAST_RUN_DIR="${TEST_TMPDIR}/mark-last-run"
    adb_mark_last_run "run_test"
    [[ -f "${LAST_RUN_DIR}/run_test" ]]
}

test_acquire_lock_creates_lock_directory() {
    LOCK_DIR="${TEST_TMPDIR}/lock-dir-create"
    LOCK_FILE=""
    adb_acquire_lock >/dev/null 2>&1
    [[ -d "${LOCK_FILE}" && -f "${LOCK_FILE}/pid" ]]
    _adb_release_lock
}

test_acquire_lock_removes_stale_lock_directory() {
    LOCK_DIR="${TEST_TMPDIR}/lock-dir-stale"
    LOCK_FILE="${LOCK_DIR}/run_phone.lock"
    mkdir -p "${LOCK_FILE}"
    printf '999999\n' >"${LOCK_FILE}/pid"

    adb_acquire_lock >/dev/null 2>&1
    [[ -d "${LOCK_FILE}" && -f "${LOCK_FILE}/pid" ]]
    _adb_release_lock
}

test_sanitize_device_string_removes_dangerous_chars() {
    local sanitized
    sanitized="$(_sanitize_device_string $'abc DEF-._:/$`";\n')"

    [[ "${sanitized}" == 'abc DEF-._:/' ]]
}

test_save_trusted_device_sanitizes_and_quotes() {
    local trusted_contents

    export ADB_SERIAL='SERIAL123$() ;'
    adb_save_trusted_device

    [[ -f "${TRUSTED_DEVICE_FILE}" ]] || return 1
    trusted_contents="$(cat "${TRUSTED_DEVICE_FILE}")"

    [[ "${trusted_contents}" != *'$('* ]]
    [[ "${trusted_contents}" != *';'* ]]
    [[ "${trusted_contents}" != *'`'* ]]

    local -a trusted_values=()
    mapfile -t trusted_values < <(
        bash -c '
            set -euo pipefail
            source "$1"
            printf "%s\n" "${TRUSTED_SERIAL:-}" "${TRUSTED_MODEL:-}" "${TRUSTED_FINGERPRINT:-}"
        ' bash "${TRUSTED_DEVICE_FILE}"
    )

    [[ "${trusted_values[0]:-}" == 'SERIAL123 ' ]]
    [[ "${trusted_values[1]:-}" == 'Pixel 7rm -rf /dangerline2' ]]
    [[ "${trusted_values[2]:-}" == 'google/pixel:14/UP1A.231005.007/evilcmd' ]]
}

test_verify_root_uses_root_shell() {
    export ADB_SERIAL='SERIAL123'
    adb_verify_root >/dev/null 2>&1
}

test_select_device_rejects_multiple_devices_even_with_trusted_record() {
    unset ADB_SERIAL

    adb_list_serials() {
        printf 'SERIAL123\nSERIAL999\n'
    }

    cat >"${TRUSTED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Pixel 7rm -rf /dangerline2'
TRUSTED_FINGERPRINT='google/pixel:14/UP1A.231005.007/evilcmd'
EOF

    if (adb_select_device >/dev/null 2>&1); then
        return 1
    fi

    return 0
}

test_verify_trusted_identity_accepts_exact_match() {
    export ADB_SERIAL='SERIAL123'
    adb_save_trusted_device
    adb_verify_trusted_identity >/dev/null 2>&1
}

test_verify_trusted_identity_rejects_model_mismatch() {
    export ADB_SERIAL='SERIAL123'
    adb_save_trusted_device

    cat >"${TRUSTED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Different Model'
TRUSTED_FINGERPRINT='google/pixel:14/UP1A.231005.007/evilcmd'
EOF

    if (adb_verify_trusted_identity >/dev/null 2>&1); then
        return 1
    fi

    return 0
}

test_verify_trusted_identity_rejects_fingerprint_mismatch() {
    export ADB_SERIAL='SERIAL123'
    adb_save_trusted_device

    cat >"${TRUSTED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Pixel 7rm -rf /dangerline2'
TRUSTED_FINGERPRINT='different/fingerprint'
EOF

    if (adb_verify_trusted_identity >/dev/null 2>&1); then
        return 1
    fi

    return 0
}

run_test "_box output without crash" test_box_does_not_crash
run_test "adb_check_cooldown 0 returns 0 (proceed)" test_check_cooldown_zero_allows
run_test "adb_check_cooldown blocks when marker is fresh" test_check_cooldown_blocks_when_marker_fresh
run_test "adb_mark_last_run creates marker file" test_mark_last_run_creates_marker
run_test "adb_acquire_lock creates atomic lock directory" test_acquire_lock_creates_lock_directory
run_test "adb_acquire_lock replaces stale lock directory" test_acquire_lock_removes_stale_lock_directory
run_test "_sanitize_device_string strips dangerous characters" test_sanitize_device_string_removes_dangerous_chars
run_test "adb_save_trusted_device sanitizes and safely quotes values" test_save_trusted_device_sanitizes_and_quotes
run_test "adb_verify_root succeeds when root shell returns ok" test_verify_root_uses_root_shell
run_test "adb_select_device rejects multiple devices even with trusted record" test_select_device_rejects_multiple_devices_even_with_trusted_record
run_test "adb_verify_trusted_identity accepts exact saved identity" test_verify_trusted_identity_accepts_exact_match
run_test "adb_verify_trusted_identity rejects model mismatch" test_verify_trusted_identity_rejects_model_mismatch
run_test "adb_verify_trusted_identity rejects fingerprint mismatch" test_verify_trusted_identity_rejects_fingerprint_mismatch

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
