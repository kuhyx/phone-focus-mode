#!/usr/bin/env bash
# lib/monitor_checks_health.sh — device-health probes behind monitor.sh:
# format indicators, battery, storage, and the three enforcer daemons.
# Each _check_* appends one JSON object to the checks file it is given.
#
# Sourced by monitor.sh, which defines every _MONITOR_* constant these read
# and the _mon_check/_trim_output/_monitor_read_pidfile helpers they call.
# Nothing is assigned here, so there is no constant to keep in step.

_check_format_indicators() {
    local outfile="$1"
    local -a missing_indicators=()
    local status="ok"
    local message="All format indicators are present"

    mapfile -t missing_indicators < <(monitor_check_format_indicators)
    if (( ${#missing_indicators[@]} >= FORMAT_DETECTION_MIN_MISSING )); then
        status="fatal"
        message="Missing ${#missing_indicators[@]} format indicators: ${missing_indicators[*]}"
    elif (( ${#missing_indicators[@]} > 0 )); then
        status="warn"
        message="Missing ${#missing_indicators[@]} format indicators: ${missing_indicators[*]}"
    fi

    _mon_check "format_indicators" "${status}" "FORMAT_INDICATORS" "${message}" "false" >>"${outfile}"
}

_check_battery() {
    local outfile="$1"
    local level=""
    local health=""
    local temp=""
    local status="ok"
    local message=""

    level="$(_trim_output "$(_safe_adb_root_output "dumpsys battery | awk -F': ' '/level:/{print \$2; exit}'")")"
    health="$(_trim_output "$(_safe_adb_root_output "dumpsys battery | awk -F': ' '/health:/{print \$2; exit}'")")"
    temp="$(_trim_output "$(_safe_adb_root_output "dumpsys battery | awk -F': ' '/temperature:/{print \$2; exit}'")")"

    if [[ ! "${level}" =~ ^[0-9]+$ ]]; then
        status="warn"
        message="Battery level unavailable"
    elif (( level < BATTERY_WARN_BELOW )); then
        status="warn"
        message="Battery low: ${level}% (threshold ${BATTERY_WARN_BELOW}%)"
    else
        message="Battery level ${level}%, health ${health:-unknown}, temp ${temp:-unknown}"
    fi

    _mon_check "battery" "${status}" "dumpsys battery" "${message}" "false" >>"${outfile}"
}

_check_storage() {
    local outfile="$1"
    local free_kb=""
    local free_mb=0
    local status="ok"
    local message=""

    free_kb="$(_trim_output "$(_safe_adb_root_output "df /sdcard 2>/dev/null | awk 'NR==2{print \$4; exit}'")")"
    if [[ ! "${free_kb}" =~ ^[0-9]+$ ]]; then
        free_kb="$(_trim_output "$(_safe_adb_root_output "df /storage/emulated/0 2>/dev/null | awk 'NR==2{print \$4; exit}'")")"
    fi

    if [[ "${free_kb}" =~ ^[0-9]+$ ]]; then
        free_mb=$((free_kb / 1024))
        if (( free_mb < STORAGE_WARN_BELOW_MB )); then
            status="warn"
            message="Low storage: ${free_mb} MB free (threshold ${STORAGE_WARN_BELOW_MB} MB)"
        else
            message="Free storage: ${free_mb} MB"
        fi
    else
        status="warn"
        message="Free storage unavailable"
    fi

    _mon_check "storage" "${status}" "df /sdcard" "${message}" "false" >>"${outfile}"
}

_check_daemon() {
    local daemon_name="$1"
    local script_name="$2"
    local pidfile="$3"
    local outfile="$4"
    local pid=""
    local pgrep_pid=""

    pid="$(_monitor_read_pidfile "${pidfile}")"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && _monitor_pid_matches_script "${pid}" "${script_name}"; then
        _mon_check "${daemon_name}" "ok" "${pidfile}" "${daemon_name} running (PID ${pid})" "false" >>"${outfile}"
        return
    fi

    pgrep_pid="$(_trim_output "$(_safe_adb_root_output "pgrep -f '${script_name}' 2>/dev/null | head -1")")"
    if [[ "${pgrep_pid}" =~ ^[0-9]+$ ]] && adb_root_shell "kill -0 ${pgrep_pid} >/dev/null 2>&1" >/dev/null 2>&1; then
        _mon_check "${daemon_name}" "ok" "pgrep -f ${script_name}" "${daemon_name} running (PID ${pgrep_pid})" "false" >>"${outfile}"
        return
    fi

    _mon_check "${daemon_name}" "error" "${pidfile}" "${daemon_name} is NOT running" "true" >>"${outfile}"
}

_check_hosts_daemon() {
    local outfile="$1"
    local resolved_target=""

    resolved_target="$(_monitor_resolve_hosts_target)"
    if [[ -z "${resolved_target}" ]]; then
        _mon_check "hosts_enforcer" "warn" "hosts target probe" \
            "No hosts target file exists on this ROM; hosts daemon check skipped" "false" >>"${outfile}"
        return
    fi

    _check_daemon "hosts_enforcer" "hosts_enforcer.sh" "${_MONITOR_REMOTE_DIR}/hosts_enforcer.pid" "${outfile}"
}

_check_launcher_daemon() {
    local outfile="$1"
    local has_snapshot="no"
    local launcher_installed="no"

    if adb_root_shell "test -s '${_MONITOR_LAUNCHER_ACTIVITY_FILE}'" >/dev/null 2>&1; then
        has_snapshot="yes"
    fi

    if adb_root_shell "pm path '${_MONITOR_LAUNCHER_PACKAGE}' >/dev/null 2>&1" >/dev/null 2>&1; then
        launcher_installed="yes"
    fi

    if [[ "${has_snapshot}" == "no" && "${launcher_installed}" == "no" ]]; then
        _mon_check "launcher_enforcer" "warn" "launcher optional probe" \
            "Launcher enforcer check skipped (launcher not configured yet)" "false" >>"${outfile}"
        return
    fi

    _check_daemon "launcher_enforcer" "launcher_enforcer.sh" "${_MONITOR_REMOTE_DIR}/launcher_enforcer.pid" "${outfile}"
}
