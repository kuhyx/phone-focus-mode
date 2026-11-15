#!/usr/bin/env bash
# lib/tests/monitor_cases_unrooted.sh — assertions for the unrooted check set
# (monitor_checks_unrooted.sh): the Pixel 6a has no `su`, so every probe must
# go through the plain `adb shell`, read-only, and root-only checks must read
# "skipped" rather than "error".
#
# Sourced by test_monitor.sh after monitor_harness.sh. The harness mocks
# adb_root_shell; this file adds an adb_cmd mock that logs every call, so the
# read-only rule is asserted against what was actually sent.
set -euo pipefail

readonly _UR_LOG="${TEST_TMPDIR}/unrooted_calls"
readonly _UR_ROOT_LOG="${TEST_TMPDIR}/unrooted_root_calls"

FORMAT_INDICATORS_UNROOTED=("Always there|true")

# Every root-shell call in unrooted mode is a bug; record it instead of
# answering, so the test can assert the log stays empty.
_ur_root_guard() {
    printf '%s\n' "$*" >>"${_UR_ROOT_LOG}"
    return 1
}

adb_cmd() {
    local args="$*"
    printf '%s\n' "${args}" >>"${_UR_LOG}"
    case "${args}" in
        'shell true') return 0 ;;
        'shell false') return 1 ;;
        *'dumpsys battery'*'level:'*) _dev_emit battery_level ;;
        *'dumpsys battery'*'health:'*) _dev_emit battery_health ;;
        *'dumpsys battery'*'temperature:'*) _dev_emit battery_temp ;;
        *'df /sdcard'*) _dev_emit df_sdcard ;;
        'shell dpm list-owners') _dev_emit owners ;;
        'shell pm list packages com.kuhy.focus_owner') _dev_emit pkg_focus_owner ;;
        'shell pm list packages com.celzero.bravedns') _dev_emit pkg_rethink ;;
        'shell settings get global private_dns_mode') _dev_emit private_dns_mode ;;
        *) return 1 ;;
    esac
}

_ur_seed_healthy() {
    _dev_reset
    : >"${_UR_LOG}"
    : >"${_UR_ROOT_LOG}"
    _dev_set battery_level 41
    _dev_set df_sdcard 23176004
    _dev_set owners $'User 0: admin=com.kuhy.focus_owner/.FocusDeviceAdminReceiver,DeviceOwner\r'
    _dev_set pkg_focus_owner $'package:com.kuhy.focus_owner\r'
    _dev_set pkg_rethink 'package:com.celzero.bravedns'
    _dev_set private_dns_mode 'opportunistic'
}

# _ur_status <report> <check> — the status of one named check in a report.
_ur_status() {
    grep -o "\"check\":\"$2\",\"status\":\"[a-z]*\"" "$1" | sed 's/.*"status":"//; s/"$//'
}

export ADB_HAS_ROOT=0
eval "_ur_saved_root_shell() $(declare -f adb_root_shell | tail -n +2)"
eval "adb_root_shell() $(declare -f _ur_root_guard | tail -n +2)"

# --- healthy unrooted phone -------------------------------------------------

_ur_seed_healthy
UR_SNAP="${TEST_TMPDIR}/unrooted_snap"
monitor_collect_snapshot "${UR_SNAP}"
UR_REPORT="${UR_SNAP}/report.json"

for name in format_indicators battery storage device_owner focus_owner_app rethinkdns private_dns; do
    _t_eq "ok" "$(_ur_status "${UR_REPORT}" "${name}")" "unrooted: ${name} is ok on a healthy phone"
done
for name in focus_daemon hosts_enforcer dns_enforcer launcher_enforcer hosts_integrity \
    dns_enforcement launcher_state companion_app boot_persistence; do
    _t_eq "skipped" "$(_ur_status "${UR_REPORT}" "${name}")" "unrooted: root-only ${name} is skipped"
done

if grep -q '"status":"error"\|"status":"fatal"' "${UR_REPORT}"; then
    _t_fail "unrooted: a healthy phone report has an error/fatal check"
else
    _t_pass "unrooted: a healthy phone report has no error/fatal check"
fi
if monitor_severity_exit "${UR_SNAP}"; then
    _t_pass "unrooted: severity_exit is 0 on a healthy phone"
else
    _t_fail "unrooted: severity_exit should be 0 on a healthy phone"
fi
_t_eq "0" "$(wc -l <"${_UR_ROOT_LOG}")" "unrooted: no probe went through the root shell"

# The hard rule: read-only `adb shell` only. Anything outside this allowlist
# (pm install/disable, settings put, dpm set-*, am, su, push) is a write.
_ur_allowed='^shell (true|false|dpm list-owners|pm list packages [a-z._]+|settings get global [a-z_]+|dumpsys battery .*|df /sdcard.*)$'
if grep -vE "${_ur_allowed}" "${_UR_LOG}" | grep -q .; then
    _t_fail "unrooted: non-allowlisted adb calls: $(grep -vE "${_ur_allowed}" "${_UR_LOG}" | tr '\n' ';')"
else
    _t_pass "unrooted: every adb call is a read-only probe"
fi

# --- drift on an unrooted phone ---------------------------------------------

_ur_seed_healthy
_dev_set owners 'No owners have been set.'
UR_SNAP2="${TEST_TMPDIR}/unrooted_snap2"
monitor_collect_snapshot "${UR_SNAP2}"
_t_eq "error" "$(_ur_status "${UR_SNAP2}/report.json" device_owner)" \
    "unrooted: a lost Device Owner is an error"

_ur_seed_healthy
rm -f "${DEV}/pkg_focus_owner" "${DEV}/pkg_rethink" "${DEV}/private_dns_mode"
UR_SNAP3="${TEST_TMPDIR}/unrooted_snap3"
monitor_collect_snapshot "${UR_SNAP3}"
_t_eq "error" "$(_ur_status "${UR_SNAP3}/report.json" focus_owner_app)" \
    "unrooted: a missing focus_owner app is an error"
_t_eq "warn" "$(_ur_status "${UR_SNAP3}/report.json" rethinkdns)" \
    "unrooted: a missing RethinkDNS is a warning"
_t_eq "warn" "$(_ur_status "${UR_SNAP3}/report.json" private_dns)" \
    "unrooted: an unreadable private DNS mode is a warning"

# --- format indicators through the plain shell ------------------------------

_ur_seed_healthy
FORMAT_INDICATORS_UNROOTED=("Kept|true" "Bogus A|false" "Bogus B|false")
: "${FORMAT_INDICATORS_UNROOTED[*]}" # read by monitor_checks_unrooted.sh
_t_eq $'Bogus A\nBogus B' "$(monitor_check_format_indicators)" \
    "unrooted: format check names each failing indicator"
_t_eq "0" "$(wc -l <"${_UR_ROOT_LOG}")" "unrooted: format check never uses the root shell"

# Restore the rooted mock for anything sourced after this file; an unset
# ADB_HAS_ROOT means rooted.
unset ADB_HAS_ROOT
eval "adb_root_shell() $(declare -f _ur_saved_root_shell | tail -n +2)"
