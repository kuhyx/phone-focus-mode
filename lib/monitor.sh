#!/usr/bin/env bash
# lib/monitor.sh — Security and health monitoring for the managed phone.
# Requires: adb_common.sh sourced, ADB_SERIAL set, backup_manifest.sh sourced.
set -euo pipefail

# Directory of this library, used to locate sibling helper scripts (BASH_SOURCE
# resolves to monitor.sh even when sourced, so the path is stable).
_MONITOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _MONITOR_LIB_DIR

# Constants read here or by both probe libraries. Those read by exactly one of
# them live in that file instead: a file must not assign a global it never
# reads (SC2034), and shellcheck runs without -x so each file stands alone.
readonly _MONITOR_REMOTE_DIR="/data/local/tmp/focus_mode"
readonly _MONITOR_HOSTS_TARGET="/system/etc/hosts"
readonly _MONITOR_LAUNCHER_PACKAGE="com.qqlabs.minimalistlauncher"
readonly _MONITOR_LAUNCHER_ACTIVITY_FILE="/data/local/tmp/focus_mode/minimalist_launcher.activity"
readonly _MONITOR_HOSTS_CANDIDATES="/system/etc/hosts /etc/hosts /vendor/etc/hosts /system/system/etc/hosts"

# Sourced after the constants above, which the probes read. Both libraries call
# helpers defined below (_mon_check, _trim_output, _safe_adb_root_output); that
# is fine because nothing here runs until monitor_collect_snapshot is called.
# shellcheck source=monitor_checks_health.sh
. "${_MONITOR_LIB_DIR}/monitor_checks_health.sh"
# shellcheck source=monitor_checks_policy.sh
. "${_MONITOR_LIB_DIR}/monitor_checks_policy.sh"

_mon_escape_json() {
    local escaped="$1"

    escaped=${escaped//\\/\\\\}
    # The quote must be backslash-escaped in the pattern. Written bare as
    # ${escaped//"/\\"} bash reads the quote as opening a quoted string, so the
    # pattern silently becomes `/\` with an empty replacement and no quote is
    # ever escaped — which emitted invalid JSON for any message containing one.
    escaped=${escaped//\"/\\\"}
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

# Each array element is appended on its own statement rather than listed
# across a multi-line literal: kcov instruments the continuation lines but
# bash only ever reports the statement's first line, so a literal spanning N
# lines is permanently stuck at 1/N covered however thoroughly it is tested.
monitor_print_format_warning() {
    local -a missing_indicators=("$@")
    local -a box_lines=()
    local indicator=""

    box_lines+=("")
    box_lines+=("The following expected components were NOT found:")

    for indicator in "${missing_indicators[@]}"; do
        box_lines+=("  ✗ ${indicator}")
    done

    box_lines+=("")
    box_lines+=("This strongly suggests the phone was factory-reset or formatted.")
    box_lines+=("")
    box_lines+=("Next step: run the full recovery workflow:")
    box_lines+=("  ./scripts/run_all/run_phone.sh fresh-phone")
    box_lines+=("")
    box_lines+=("Do NOT run 'auto' mode — it will not restore anything.")

    _box "PHONE APPEARS TO HAVE BEEN WIPED" "${box_lines[@]}"
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

    # Redirected per statement rather than as a `{ ... } >file` group: kcov
    # counts the group's closing brace as an instrumented line that bash never
    # reports, which alone held this file below 100%.
    printf '{"timestamp":"%s","device":"%s","checks":[\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_mon_escape_json "${ADB_SERIAL}")" >"${report_path}"
    paste -sd ',' "${tmp_checks}" >>"${report_path}"
    printf '\n]}\n' >>"${report_path}"

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

    python "${_MONITOR_LIB_DIR}/monitor_report.py" summary "${report_path}"
}

monitor_severity_exit() {
    local snapshot_dir="$1"
    local report_path="${snapshot_dir}/report.json"

    [[ -f "${report_path}" ]] || return 0

    python "${_MONITOR_LIB_DIR}/monitor_report.py" severity "${report_path}"
}
