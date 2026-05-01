#!/usr/bin/env bash
# Unit tests for monitor.sh helpers that do not require a real device.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

adb_root_shell() {
    return 1
}

_info() {
    :
}

_warn() {
    :
}

_error() {
    :
}

_fatal() {
    printf 'FATAL: %s\n' "$*" >&2
    exit 1
}

_box() {
    :
}

FORMAT_INDICATORS=()
FORMAT_DETECTION_MIN_MISSING=2
BATTERY_WARN_BELOW=20
STORAGE_WARN_BELOW_MB=500
ADB_SERIAL="test-serial"

: "${FORMAT_DETECTION_MIN_MISSING}"
: "${BATTERY_WARN_BELOW}"
: "${STORAGE_WARN_BELOW_MB}"
: "${ADB_SERIAL}"
: "${FORMAT_INDICATORS[*]}"

source "${SCRIPT_DIR}/../monitor.sh"

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

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

line="$(_mon_check "test_check" "ok" "some_cmd" "all good" "false")"
if [[ "${line}" == *'"check":"test_check"'* ]]; then
    _t_pass "_mon_check outputs check name"
else
    _t_fail "_mon_check missing check name"
fi

if [[ "${line}" == *'"status":"ok"'* ]]; then
    _t_pass "_mon_check outputs status"
else
    _t_fail "_mon_check missing status"
fi

if [[ -z "$(_monitor_resolve_hosts_target)" ]]; then
    _t_pass "_monitor_resolve_hosts_target returns empty when no hosts file exists"
else
    _t_fail "_monitor_resolve_hosts_target should be empty when all candidates are missing"
fi

adb_root_shell() {
    case "$*" in
        'test -f /system/etc/hosts') return 1 ;;
        'test -f /etc/hosts') return 1 ;;
        'test -f /vendor/etc/hosts') return 0 ;;
        'test -f /system/system/etc/hosts') return 1 ;;
        *) return 1 ;;
    esac
}

if [[ "$(_monitor_resolve_hosts_target)" == "/vendor/etc/hosts" ]]; then
    _t_pass "_monitor_resolve_hosts_target picks first existing candidate"
else
    _t_fail "_monitor_resolve_hosts_target did not return expected candidate"
fi

adb_root_shell() {
    return 1
}

if ! monitor_is_formatted 2>/dev/null; then
    _t_pass "monitor_is_formatted returns 1 when no indicators are missing"
else
    _t_fail "monitor_is_formatted should return 1 with empty FORMAT_INDICATORS"
fi

if monitor_severity_exit "${TMPDIR_TEST}/nonexistent"; then
    _t_pass "monitor_severity_exit returns 0 when no report exists"
else
    _t_fail "monitor_severity_exit should return 0 for missing report"
fi

printf '%s\n' '{"checks":[{"check":"x","status":"fatal","source":"s","message":"m","repairable":false}]}' > "${TMPDIR_TEST}/report.json"
if ! monitor_severity_exit "${TMPDIR_TEST}"; then
    _t_pass "monitor_severity_exit returns 1 on fatal status"
else
    _t_fail "monitor_severity_exit should return 1 on fatal status"
fi

printf '%s\n' '{"checks":[{"check":"x","status":"ok","source":"s","message":"mentions fatal and error in text","repairable":false}]}' > "${TMPDIR_TEST}/report.json"
if monitor_severity_exit "${TMPDIR_TEST}"; then
    _t_pass "monitor_severity_exit ignores free-text fatal/error words in message"
else
    _t_fail "monitor_severity_exit should only inspect the JSON status field"
fi

FORMAT_INDICATORS=(
    "present|test -f /present"
    "missing-one|test -f /missing-one"
    "missing-two|test -f /missing-two"
)

: "${FORMAT_INDICATORS[*]}"

adb_root_shell() {
    case "$*" in
        'test -f /present')
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

mapfile -t missing_indicators < <(monitor_check_format_indicators)
if [[ ${#missing_indicators[@]} -eq 2 ]] && [[ "${missing_indicators[0]}" == "missing-one" ]] && [[ "${missing_indicators[1]}" == "missing-two" ]]; then
    _t_pass "monitor_check_format_indicators prints only missing indicator names"
else
    _t_fail "monitor_check_format_indicators did not return the expected missing indicators"
fi

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
