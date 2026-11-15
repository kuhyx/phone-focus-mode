#!/usr/bin/env bash
# lib/monitor_checks_unrooted.sh — the check set for a phone without root
# (the Pixel 6a: stock, locked, Device Owner = com.kuhy.focus_owner).
#
# Hard rule: every probe here is a READ through the plain `adb shell`
# (dpm list-owners, pm list packages, settings get, dumpsys, df). Nothing
# here may call pm install/disable, settings put, dpm set-*, am or su; the
# unrooted tests assert that against a log of every adb call.
#
# The rooted checks (daemons, hosts, iptables, launcher, boot script) read
# paths that only exist under Magisk. On an unrooted phone they are reported
# as "skipped", never "error", so a healthy phone exits 0.
#
# Sourced by monitor.sh, which defines _mon_check, _trim_output and
# _safe_adb_root_output. adb_cmd comes from adb_common.sh.

readonly _MONITOR_OWNER_PACKAGE="com.kuhy.focus_owner"
readonly _MONITOR_RETHINK_PACKAGE="com.celzero.bravedns"
readonly _MONITOR_ROOT_ONLY_CHECKS="focus_daemon hosts_enforcer dns_enforcer launcher_enforcer hosts_integrity dns_enforcement launcher_state companion_app boot_persistence"

# Root unless adb_detect_root said otherwise, so callers that never ran the
# detection (the rooted test harness, older entry points) keep the old path.
_mon_has_root() {
    [[ "${ADB_HAS_ROOT:-1}" == "1" ]]
}

# Output of one read-only probe, through su when rooted, else the plain shell.
_safe_adb_read_output() {
    if _mon_has_root; then
        _safe_adb_root_output "$@"
    else
        adb_cmd shell "$*" 2>/dev/null || true
    fi
}

_monitor_check_format_indicators_unrooted() {
    local indicator="" description="" command_text=""

    for indicator in "${FORMAT_INDICATORS_UNROOTED[@]}"; do
        description="${indicator%%|*}"
        command_text="${indicator#*|}"
        adb_cmd shell "${command_text}" >/dev/null 2>&1 || printf '%s\n' "${description}"
    done
}

_unrooted_has_package() {
    adb_cmd shell pm list packages "$1" 2>/dev/null | tr -d '\r' | grep -qxF "package:$1"
}

_check_device_owner() {
    local outfile="$1" owners=""

    owners="$(adb_cmd shell dpm list-owners 2>/dev/null | tr -d '\r' || true)"
    if grep -q "${_MONITOR_OWNER_PACKAGE}/.*DeviceOwner" <<<"${owners}"; then
        _mon_check "device_owner" "ok" "dpm list-owners" "Device Owner is ${_MONITOR_OWNER_PACKAGE}" "false" >>"${outfile}"
    else
        _mon_check "device_owner" "error" "dpm list-owners" \
            "Device Owner is NOT ${_MONITOR_OWNER_PACKAGE}: $(_trim_output "${owners}")" "false" >>"${outfile}"
    fi
}

_check_owner_app() {
    local outfile="$1"

    if _unrooted_has_package "${_MONITOR_OWNER_PACKAGE}"; then
        _mon_check "focus_owner_app" "ok" "pm list packages" "${_MONITOR_OWNER_PACKAGE} installed" "false" >>"${outfile}"
    else
        _mon_check "focus_owner_app" "error" "pm list packages" "${_MONITOR_OWNER_PACKAGE} is NOT installed" "false" >>"${outfile}"
    fi
}

_check_rethinkdns() {
    local outfile="$1"

    if _unrooted_has_package "${_MONITOR_RETHINK_PACKAGE}"; then
        _mon_check "rethinkdns" "ok" "pm list packages" "RethinkDNS installed" "false" >>"${outfile}"
    else
        _mon_check "rethinkdns" "warn" "pm list packages" "RethinkDNS (${_MONITOR_RETHINK_PACKAGE}) is NOT installed" "false" >>"${outfile}"
    fi
}

_check_private_dns() {
    local outfile="$1" mode=""

    mode="$(_trim_output "$(adb_cmd shell settings get global private_dns_mode 2>/dev/null || true)")"
    if [[ -n "${mode}" ]]; then
        _mon_check "private_dns" "ok" "settings get global private_dns_mode" "Private DNS mode: ${mode}" "false" >>"${outfile}"
    else
        _mon_check "private_dns" "warn" "settings get global private_dns_mode" "Private DNS mode unavailable" "false" >>"${outfile}"
    fi
}

_check_root_only_skipped() {
    local outfile="$1" name=""

    for name in ${_MONITOR_ROOT_ONLY_CHECKS}; do
        _mon_check "${name}" "skipped" "needs root" "Root-only check; this phone is unrooted" "false" >>"${outfile}"
    done
}

_monitor_collect_unrooted() {
    local outfile="$1"

    _check_format_indicators "${outfile}"
    _check_battery "${outfile}"
    _check_storage "${outfile}"
    _check_device_owner "${outfile}"
    _check_owner_app "${outfile}"
    _check_rethinkdns "${outfile}"
    _check_private_dns "${outfile}"
    _check_root_only_skipped "${outfile}"
}
