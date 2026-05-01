#!/usr/bin/env bash
# lib/monitor.sh — Security and health monitoring for the managed phone.
# Requires: adb_common.sh sourced, ADB_SERIAL set, backup_manifest.sh sourced.
set -euo pipefail

readonly _MONITOR_REMOTE_DIR="/data/local/tmp/focus_mode"
readonly _MONITOR_HOSTS_CANONICAL="/data/local/tmp/focus_mode/hosts.canonical"
readonly _MONITOR_HOSTS_SHA_FILE="/data/local/tmp/focus_mode/hosts.sha256"
readonly _MONITOR_HOSTS_TARGET="/system/etc/hosts"
readonly _MONITOR_BOOT_SCRIPT="/data/adb/service.d/99-focus-mode.sh"
readonly _MONITOR_LAUNCHER_PACKAGE="com.qqlabs.minimalistlauncher"
readonly _MONITOR_LAUNCHER_ACTIVITY_FILE="/data/local/tmp/focus_mode/minimalist_launcher.activity"
readonly _MONITOR_COMPANION_PACKAGE="com.kuhy.focusstatus"
readonly _MONITOR_DNS_CHAIN="FOCUS_DNS_BLOCK"
readonly _MONITOR_HOSTS_CANDIDATES="/system/etc/hosts /etc/hosts /vendor/etc/hosts /system/system/etc/hosts"

_mon_escape_json() {
    local escaped="$1"

    escaped=${escaped//\\/\\\\}
    escaped=${escaped//"/\\"}
    escaped=${escaped//$'\n'/\\n}
    escaped=${escaped//$'\r'/\\r}
    printf '%s' "${escaped}"
}

_mon_check() {
    local check_name="$1"
    local status="$2"
    local source_cmd="$3"
    local message="$4"
    local repairable="${5:-false}"

    printf '{"check":"%s","status":"%s","source":"%s","message":"%s","repairable":%s}\n' \
        "$(_mon_escape_json "${check_name}")" \
        "$(_mon_escape_json "${status}")" \
        "$(_mon_escape_json "${source_cmd}")" \
        "$(_mon_escape_json "${message}")" \
        "${repairable}"
}

_safe_adb_root_output() {
    adb_root_shell "$@" 2>/dev/null || true
}

_trim_output() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

_monitor_read_pidfile() {
    local pidfile="$1"
    local pid=""

    pid="$(_trim_output "$(_safe_adb_root_output "if [ -f ${pidfile} ]; then cat ${pidfile}; fi")")"
    printf '%s' "${pid}"
}

_monitor_resolve_hosts_target() {
    local candidate=""

    if adb_root_shell "test -f ${_MONITOR_HOSTS_TARGET}" >/dev/null 2>&1; then
        printf '%s' "${_MONITOR_HOSTS_TARGET}"
        return 0
    fi

    for candidate in ${_MONITOR_HOSTS_CANDIDATES}; do
        if adb_root_shell "test -f ${candidate}" >/dev/null 2>&1; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    printf ''
}

_monitor_pid_matches_script() {
    local pid="$1"
    local script_name="$2"

    adb_root_shell "kill -0 ${pid} >/dev/null 2>&1" >/dev/null 2>&1 || return 1

    adb_root_shell "tr '\\0' ' ' </proc/${pid}/cmdline | grep -q ${script_name}" >/dev/null 2>&1 && return 0

    # Some Android shells hide/normalize cmdline under su; if PID is alive,
    # trust the pidfile check to avoid false negatives.
    return 0
}

monitor_check_format_indicators() {
    local indicator=""
    local description=""
    local command_text=""

    for indicator in "${FORMAT_INDICATORS[@]}"; do
        description="${indicator%%|*}"
        command_text="${indicator#*|}"
        if ! adb_root_shell "${command_text}" >/dev/null 2>&1; then
            printf '%s\n' "${description}"
        fi
    done
}

monitor_count_missing_format_indicators() {
    local -a missing_indicators=()

    mapfile -t missing_indicators < <(monitor_check_format_indicators)
    printf '%s\n' "${#missing_indicators[@]}"
}

monitor_is_formatted() {
    local missing_count=""

    missing_count="$(monitor_count_missing_format_indicators)"
    [[ "${missing_count}" =~ ^[0-9]+$ ]] || _fatal "Format-detection helper returned a non-numeric count: ${missing_count}"
    (( missing_count >= FORMAT_DETECTION_MIN_MISSING ))
}

monitor_print_format_warning() {
    local -a missing_indicators=("$@")
    local -a box_lines=(
        ""
        "The following expected components were NOT found:"
    )
    local indicator=""

    for indicator in "${missing_indicators[@]}"; do
        box_lines+=("  ✗ ${indicator}")
    done

    box_lines+=(
        ""
        "This strongly suggests the phone was factory-reset or formatted."
        ""
        "Next step: run the full recovery workflow:"
        "  ./scripts/run_all/run_phone.sh fresh-phone"
        ""
        "Do NOT run 'auto' mode — it will not restore anything."
    )

    _box "PHONE APPEARS TO HAVE BEEN WIPED" "${box_lines[@]}"
}

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

monitor_collect_snapshot() {
    local snapshot_dir="$1"
    local tmp_checks=""
    local report_path="${snapshot_dir}/report.json"

    mkdir -p "${snapshot_dir}"
    tmp_checks="$(mktemp)"

    _check_format_indicators "${tmp_checks}"
    _check_battery "${tmp_checks}"
    _check_storage "${tmp_checks}"
    _check_daemon "focus_daemon" "focus_daemon.sh" "${_MONITOR_REMOTE_DIR}/daemon.pid" "${tmp_checks}"
    _check_hosts_daemon "${tmp_checks}"
    _check_daemon "dns_enforcer" "dns_enforcer.sh" "${_MONITOR_REMOTE_DIR}/dns_enforcer.pid" "${tmp_checks}"
    _check_launcher_daemon "${tmp_checks}"
    _check_hosts_integrity "${tmp_checks}"
    _check_dns "${tmp_checks}"
    _check_launcher "${tmp_checks}"
    _check_companion_app "${tmp_checks}"
    _check_boot_persistence "${tmp_checks}"

    {
        printf '{"timestamp":"%s","device":"%s","checks":[\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$( _mon_escape_json "${ADB_SERIAL}" )"
        paste -sd ',' "${tmp_checks}"
        printf '\n]}\n'
    } >"${report_path}"

    cp "${report_path}" "$(dirname "${snapshot_dir}")/latest.json" 2>/dev/null || true
    rm -f "${tmp_checks}"
}

monitor_print_summary() {
    local snapshot_dir="$1"
    local report_path="${snapshot_dir}/report.json"

    [[ -f "${report_path}" ]] || {
        _warn "No report found at ${report_path}"
        return 0
    }

    python - "${report_path}" <<'PY'
import json
import sys

report_path = sys.argv[1]
with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)

counts = {"ok": 0, "warn": 0, "error": 0, "fatal": 0}
issues = []
for check in report.get("checks", []):
    status = check.get("status", "warn")
    counts[status] = counts.get(status, 0) + 1
    if status in {"warn", "error", "fatal"}:
        issues.append((status, check.get("check", "unknown"), check.get("message", "")))

print("\n=== Monitoring Summary ===")
print(
    f"  ok={counts.get('ok', 0):<3}  warn={counts.get('warn', 0):<3}  "
    f"error={counts.get('error', 0):<3}  fatal={counts.get('fatal', 0):<3}"
)
if issues:
    print("\nIssues found:")
    for status, check_name, message in issues:
        print(f"  [{status}] {check_name}: {message}")
print("==========================\n")
PY
}

monitor_severity_exit() {
    local snapshot_dir="$1"
    local report_path="${snapshot_dir}/report.json"

    [[ -f "${report_path}" ]] || return 0

    python - "${report_path}" <<'PY'
import json
import sys

report_path = sys.argv[1]
with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)

has_severe = any(
    check.get("status") in {"fatal", "error"}
    for check in report.get("checks", [])
)
raise SystemExit(1 if has_severe else 0)
PY
}
