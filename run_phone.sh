#!/usr/bin/env bash
# run_phone.sh — Phone focus mode orchestrator.
#
# Usage:
#   run_phone.sh [auto]           Everyday: backup, monitor, repair minor drift.
#                                 If the phone looks formatted, shows a warning
#                                 and exits — does nothing else.
#   run_phone.sh fresh-phone      Full recovery after a factory reset.
#   run_phone.sh backup           Incremental backup only.
#   run_phone.sh monitor          Health and security snapshot only.
#   run_phone.sh doctor           Diagnose and repair drift without data restore.
#   run_phone.sh --help | -h      Show this help.
#
# Environment variables:
#   ADB_SERIAL          Target a specific device by serial.
#   PHONE_BACKUP_ROOT   Override backup root (default: ~/phone_backups).
#   PHONE_IP            Wireless ADB host (used by deploy.sh when ADB_SERIAL unset).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/adb_common.sh
source "${_SCRIPT_DIR}/lib/adb_common.sh"
# shellcheck source=backup_manifest.sh
source "${_SCRIPT_DIR}/backup_manifest.sh"
# shellcheck source=lib/monitor.sh
source "${_SCRIPT_DIR}/lib/monitor.sh"
# shellcheck source=lib/backup.sh
source "${_SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/restore.sh
source "${_SCRIPT_DIR}/lib/restore.sh"

SUBCOMMAND="${1:-auto}"
shift 2>/dev/null || true

case "${SUBCOMMAND}" in
    --help|-h|help)
        grep '^#' "${BASH_SOURCE[0]}" | grep -v '^#!/' | grep -v '^# shellcheck ' | sed 's/^# \?//'
        exit 0
        ;;
    auto|fresh-phone|backup|monitor|doctor) ;;
    *)
        _fatal "Unknown subcommand: '${SUBCOMMAND}'. Run with --help for usage."
        ;;
esac

_setup_common() {
    adb_select_device "${ADB_SERIAL:-}"
    adb_verify_root
    adb_verify_trusted_identity
    adb_collect_identity
}

_auto_repair_minor_drift() {
    local snapshot_dir="$1"
    local report="${snapshot_dir}/report.json"
    local repaired=0

    [[ -f "${report}" ]] || return 0

    if grep -q '"check":"focus_daemon","status":"error"' "${report}" 2>/dev/null; then
        if adb_root_shell "test -x /data/adb/service.d/99-focus-mode.sh" >/dev/null 2>&1; then
            _info "Repair: restarting focus daemons via boot script"
            adb_root_shell "sh /data/adb/service.d/99-focus-mode.sh" >/dev/null 2>&1 || true
            repaired=$(( repaired + 1 ))
        else
            _warn "Cannot restart daemons: boot script missing. Run 'fresh-phone' or 'doctor'."
        fi
    fi

    [[ ${repaired} -gt 0 ]] && _info "Minor repairs applied: ${repaired}" || true
}

cmd_auto() {
    adb_acquire_lock

    if ! adb_check_cooldown "${COOLDOWN_AUTO_SECS}" "auto"; then
        _info "auto: cooldown active, nothing to do."
        exit 0
    fi

    _setup_common

    # Detect fresh format FIRST and exit immediately if detected.
    local -a missing
    mapfile -t missing < <(monitor_check_format_indicators)
    local missing_count="${#missing[@]}"
    if (( missing_count >= FORMAT_DETECTION_MIN_MISSING )); then
        monitor_print_format_warning "${missing[@]}"
        exit 2
    fi

    local device_id="${ADB_SERIAL//[^a-zA-Z0-9_-]/_}"
    local snapshot_dir=""
    snapshot_dir="${PHONE_BACKUP_ROOT}/${device_id}/monitoring/$(date -u +%Y%m%dT%H%M%SZ)"

    monitor_collect_snapshot "${snapshot_dir}"
    backup_run_incremental "${device_id}"
    _auto_repair_minor_drift "${snapshot_dir}"

    monitor_print_summary "${snapshot_dir}"
    adb_mark_last_run "auto"
    monitor_severity_exit "${snapshot_dir}" || exit 1
}

cmd_fresh_phone() {
    _info "=== fresh-phone: Full recovery mode ==="
    adb_select_device "${ADB_SERIAL:-}"

    restore_verify_prerequisites

    adb_collect_identity
    local device_id="${ADB_SERIAL//[^a-zA-Z0-9_-]/_}"
    local backup_root="${PHONE_BACKUP_ROOT}/${device_id}/latest"
    local has_backup=0

    if [[ -d "${backup_root}" ]]; then
        has_backup=1
    else
        _warn "No backup found at ${backup_root}. Proceeding with security-stack-only setup."
    fi

    local pre_snapshot=""
    pre_snapshot="${PHONE_BACKUP_ROOT}/${device_id}/monitoring/pre_restore_$(date -u +%Y%m%dT%H%M%SZ)"
    monitor_collect_snapshot "${pre_snapshot}" || true

    # Delegate security restore to deploy.sh via restore helper.
    restore_security_stack

    if (( has_backup == 1 )); then
        restore_apks "${backup_root}"
        restore_media "${backup_root}"
    else
        _warn "Skipping APK/media restore because no backup snapshot is available."
    fi

    local post_snapshot=""
    post_snapshot="${PHONE_BACKUP_ROOT}/${device_id}/monitoring/post_restore_$(date -u +%Y%m%dT%H%M%SZ)"
    monitor_collect_snapshot "${post_snapshot}" || true
    monitor_print_summary "${post_snapshot}"

    adb_save_trusted_device
    if (( has_backup == 1 )); then
        restore_print_manual_steps "${backup_root}"
    else
        _box "BACKUP RESTORE SKIPPED" \
            "" \
            "Security stack deployment completed, but no backup snapshot was found." \
            "Next steps:" \
            "  ▶ Run './scripts/run_all/run_phone.sh backup' after stabilization" \
            "  ▶ Reinstall required apps that are not part of deploy assets" \
            "  ▶ Reconfigure app data manually"
    fi
}

cmd_backup() {
    _setup_common
    local device_id="${ADB_SERIAL//[^a-zA-Z0-9_-]/_}"
    backup_run_incremental "${device_id}"
}

cmd_monitor() {
    _setup_common
    local device_id="${ADB_SERIAL//[^a-zA-Z0-9_-]/_}"
    local snapshot_dir=""
    snapshot_dir="${PHONE_BACKUP_ROOT}/${device_id}/monitoring/$(date -u +%Y%m%dT%H%M%SZ)"
    monitor_collect_snapshot "${snapshot_dir}"
    monitor_print_summary "${snapshot_dir}"
    monitor_severity_exit "${snapshot_dir}" || exit 1
}

cmd_doctor() {
    _setup_common
    local device_id="${ADB_SERIAL//[^a-zA-Z0-9_-]/_}"
    local snapshot_dir=""
    snapshot_dir="${PHONE_BACKUP_ROOT}/${device_id}/monitoring/doctor_$(date -u +%Y%m%dT%H%M%SZ)"
    local report=""
    local repaired=0

    monitor_collect_snapshot "${snapshot_dir}"
    report="${snapshot_dir}/report.json"

    local daemon=""
    for daemon in focus_daemon hosts_enforcer dns_enforcer launcher_enforcer; do
        if grep -q "\"check\":\"${daemon}\",\"status\":\"error\"" "${report}" 2>/dev/null; then
            _info "Doctor: restarting ${daemon}"
            adb_root_shell "pgrep -f ${daemon}.sh | xargs kill -9 2>/dev/null || true" >/dev/null 2>&1 || true
            adb_root_shell "nohup sh /data/adb/focus_mode/${daemon}.sh </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1 || \
                _warn "Could not restart ${daemon}"
            repaired=$(( repaired + 1 ))
        fi
    done

    # Re-deploy is allowed only for managed security-stack drift.
    if grep -q '"check":"boot_persistence","status":"fatal"' "${report}" 2>/dev/null; then
        _info "Doctor: boot script missing — re-running deploy.sh"
        restore_security_stack
        repaired=$(( repaired + 1 ))
    fi

    if grep -q '"check":"hosts_integrity","status":"error"' "${report}" 2>/dev/null; then
        if [[ -f "${PHONE_BACKUP_ROOT}/${device_id}/latest/security_state/data/local/tmp/focus_mode/hosts.canonical" ]]; then
            _info "Doctor: restoring canonical hosts from backup"
            adb_cmd push \
                "${PHONE_BACKUP_ROOT}/${device_id}/latest/security_state/data/local/tmp/focus_mode/hosts.canonical" \
                "/data/local/tmp/focus_mode/hosts.canonical"
            repaired=$(( repaired + 1 ))
        else
            _warn "Doctor: hosts integrity failed but no backup copy available. Run fresh-phone."
        fi
    fi

    monitor_collect_snapshot "${snapshot_dir}_after"
    monitor_print_summary "${snapshot_dir}_after"

    _info "Doctor complete. Repairs applied: ${repaired}"
    monitor_severity_exit "${snapshot_dir}_after" || {
        _warn "Unresolved issues remain after doctor run."
        exit 1
    }
}

case "${SUBCOMMAND}" in
    auto)        cmd_auto ;;
    fresh-phone) cmd_fresh_phone ;;
    backup)      cmd_backup ;;
    monitor)     cmd_monitor ;;
    doctor)      cmd_doctor ;;
esac
