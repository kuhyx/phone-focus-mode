#!/usr/bin/env bash
# lib/monitor_checks_policy.sh — enforcement-integrity probes behind monitor.sh:
# the hosts blocklist, DNS chain, launcher, companion app and boot persistence.
# Each _check_* appends one JSON object to the checks file it is given.
#
# Sourced by monitor.sh, which defines _MONITOR_LAUNCHER_PACKAGE and
# _MONITOR_LAUNCHER_ACTIVITY_FILE (shared with the health probes) plus the
# _mon_check/_trim_output/_safe_adb_root_output helpers these call.
# The constants below are read only here, so they are assigned only here.

readonly _MONITOR_HOSTS_CANONICAL="/data/local/tmp/focus_mode/hosts.canonical"
readonly _MONITOR_HOSTS_SHA_FILE="/data/local/tmp/focus_mode/hosts.sha256"
readonly _MONITOR_BOOT_SCRIPT="/data/adb/service.d/99-focus-mode.sh"
readonly _MONITOR_COMPANION_PACKAGE="com.kuhy.focusstatus"
readonly _MONITOR_DNS_CHAIN="FOCUS_DNS_BLOCK"

_check_hosts_integrity() {
    local outfile="$1"
    local hosts_target=""
    local expected_hash=""
    local actual_hash=""

    hosts_target="$(_monitor_resolve_hosts_target)"
    if [[ -z "${hosts_target}" ]]; then
        _mon_check "hosts_integrity" "warn" "hosts target probe" \
            "No hosts file target exists on this ROM; hosts integrity check skipped" "false" >>"${outfile}"
        return
    fi

    if ! adb_root_shell "test -f ${_MONITOR_HOSTS_CANONICAL}" >/dev/null 2>&1; then
        _mon_check "hosts_integrity" "fatal" "${_MONITOR_HOSTS_CANONICAL}" \
            "Canonical hosts file missing at ${_MONITOR_HOSTS_CANONICAL}" "true" >>"${outfile}"
        return
    fi

    expected_hash="$(_trim_output "$(_safe_adb_root_output "cat ${_MONITOR_HOSTS_SHA_FILE} 2>/dev/null")")"
    actual_hash="$(_trim_output "$(_safe_adb_root_output "sha256sum ${hosts_target} 2>/dev/null | awk '{print \$1}'")")"

    if [[ -z "${expected_hash}" || -z "${actual_hash}" ]]; then
        _mon_check "hosts_integrity" "error" "${hosts_target}" \
            "Could not read hosts integrity hashes" "true" >>"${outfile}"
    elif [[ "${expected_hash}" == "${actual_hash}" ]]; then
        _mon_check "hosts_integrity" "ok" "${hosts_target}" \
            "Hosts file matches canonical (${actual_hash:0:12}…)" "false" >>"${outfile}"
    else
        _mon_check "hosts_integrity" "error" "${hosts_target}" \
            "Hosts mismatch: active ${actual_hash:0:12}… != expected ${expected_hash:0:12}…" "true" >>"${outfile}"
    fi
}

_check_dns() {
    local outfile="$1"
    local private_dns_mode=""
    local chain_present="no"
    local status="ok"
    local message=""

    private_dns_mode="$(_trim_output "$(_safe_adb_root_output "settings get global private_dns_mode 2>/dev/null")")"
    if adb_root_shell "iptables -L ${_MONITOR_DNS_CHAIN} >/dev/null 2>&1 && ip6tables -L ${_MONITOR_DNS_CHAIN} >/dev/null 2>&1" >/dev/null 2>&1; then
        chain_present="yes"
    fi

    if [[ "${private_dns_mode}" == "off" || "${private_dns_mode}" == "null" || -z "${private_dns_mode}" ]]; then
        if [[ "${chain_present}" == "yes" ]]; then
            message="Private DNS disabled and DNS firewall chains present"
        else
            status="error"
            message="Private DNS disabled, but DNS firewall chains are missing"
        fi
    else
        status="error"
        message="Private DNS is enabled (mode=${private_dns_mode})"
    fi

    _mon_check "dns_enforcement" "${status}" "settings get global private_dns_mode" "${message}" "true" >>"${outfile}"
}

_check_launcher() {
    local outfile="$1"
    local desired_activity=""
    local actual_activity=""
    local has_snapshot="no"

    if adb_root_shell "test -s '${_MONITOR_LAUNCHER_ACTIVITY_FILE}'" >/dev/null 2>&1; then
        has_snapshot="yes"
    fi

    if ! adb_root_shell "pm path '${_MONITOR_LAUNCHER_PACKAGE}' >/dev/null 2>&1" >/dev/null 2>&1; then
        if [[ "${has_snapshot}" == "yes" ]]; then
            _mon_check "launcher_state" "fatal" "pm path ${_MONITOR_LAUNCHER_PACKAGE}" \
                "Minimalist launcher is not installed but snapshot metadata exists" "true" >>"${outfile}"
        else
            _mon_check "launcher_state" "warn" "pm path ${_MONITOR_LAUNCHER_PACKAGE}" \
                "Minimalist launcher is not installed (optional until snapshot is configured)" "false" >>"${outfile}"
        fi
        return
    fi

    desired_activity="$(_trim_output "$(_safe_adb_root_output "cat ${_MONITOR_LAUNCHER_ACTIVITY_FILE} 2>/dev/null")")"
    actual_activity="$(_trim_output "$(_safe_adb_root_output "cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null | awk 'NR==2{print}'")")"

    if [[ -z "${desired_activity}" ]]; then
        _mon_check "launcher_state" "warn" "cat ${_MONITOR_LAUNCHER_ACTIVITY_FILE}" \
            "Launcher snapshot metadata is missing or empty" "true" >>"${outfile}"
    elif [[ -n "${actual_activity}" && "${desired_activity}" != "${actual_activity}" ]]; then
        _mon_check "launcher_state" "error" "cmd package resolve-activity" \
            "Launcher default mismatch: expected ${desired_activity}, got ${actual_activity}" "true" >>"${outfile}"
    else
        _mon_check "launcher_state" "ok" "pm path ${_MONITOR_LAUNCHER_PACKAGE}" \
            "Minimalist launcher installed and HOME activity aligned" "false" >>"${outfile}"
    fi
}

_check_companion_app() {
    local outfile="$1"

    if adb_root_shell "pm list packages -e '${_MONITOR_COMPANION_PACKAGE}' 2>/dev/null | grep -q '${_MONITOR_COMPANION_PACKAGE}'" >/dev/null 2>&1; then
        _mon_check "companion_app" "ok" "pm list packages -e ${_MONITOR_COMPANION_PACKAGE}" \
            "Focus companion app is installed" "false" >>"${outfile}"
    else
        _mon_check "companion_app" "warn" "pm list packages -e ${_MONITOR_COMPANION_PACKAGE}" \
            "Focus companion app is missing" "true" >>"${outfile}"
    fi
}

_check_boot_persistence() {
    local outfile="$1"

    if adb_root_shell "test -x ${_MONITOR_BOOT_SCRIPT}" >/dev/null 2>&1; then
        _mon_check "boot_persistence" "ok" "test -x ${_MONITOR_BOOT_SCRIPT}" \
            "Magisk boot script present and executable" "false" >>"${outfile}"
    else
        _mon_check "boot_persistence" "fatal" "test -x ${_MONITOR_BOOT_SCRIPT}" \
            "Magisk boot script missing or not executable" "true" >>"${outfile}"
    fi
}
