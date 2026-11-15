#!/usr/bin/env bash
# run_phone.sh — Phone focus mode orchestrator.
#
# Usage:
#   run_phone.sh [auto]           Everyday: backup, monitor, repair minor drift.
#                                 If the phone looks formatted, shows a warning
#                                 and exits — does nothing else.
#   run_phone.sh enroll           Trust the connected phone, so `auto` (and the
#                                 phone-auto-sync timer) acts on it. Writes
#                                 nothing to the phone.
#   run_phone.sh fresh-phone      Full recovery after a factory reset.
#   run_phone.sh backup           Incremental backup only.
#   run_phone.sh monitor          Health and security snapshot only.
#   run_phone.sh doctor           Diagnose and repair drift without data restore.
#   run_phone.sh --help | -h      Show this help.
#
# Unrooted phones: `backup`, `monitor`, `auto` and `enroll` work without root,
# read-only (adb shell reads + adb pull, never a write to the phone). backup
# pulls package lists, all third-party APKs, shared storage and settings;
# monitor checks battery, storage, Device Owner and the focus apps and marks
# root-only checks "skipped"; auto backs up at most once a day. `fresh-phone`
# and `doctor` write to the phone and still need root (Magisk).
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
# shellcheck source=lib/doctor.sh
source "${_SCRIPT_DIR}/lib/doctor.sh"

SUBCOMMAND="${1:-auto}"
shift 2>/dev/null || true

case "${SUBCOMMAND}" in
    --help|-h|help)
        # The header comment block only: later top-level comments are notes
        # for maintainers, not usage.
        awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    auto|enroll|fresh-phone|backup|monitor|doctor) ;;
    *)
        _fatal "Unknown subcommand: '${SUBCOMMAND}'. Run with --help for usage."
        ;;
esac

_setup_common() {
    adb_select_device "${ADB_SERIAL:-}"
    adb_detect_root
    adb_verify_trusted_identity
    adb_collect_identity
}

_auto_repair_minor_drift() {
    local snapshot_dir="$1"
    local report="${snapshot_dir}/report.json"
    local repaired=0

    [[ -f "${report}" ]] || return 0
    # Every repair below is a root-shell write; an unrooted phone gets none.
    [[ "${ADB_HAS_ROOT:-1}" == "1" ]] || return 0

    if grep -q '"check":"focus_daemon","status":"error"' "${report}" 2>/dev/null; then
        if adb_root_shell "test -x /data/adb/service.d/99-focus-mode.sh" >/dev/null 2>&1; then
            _info "Repair: restarting focus daemons via boot script"
            adb_root_shell "sh /data/adb/service.d/99-focus-mode.sh" >/dev/null 2>&1 || true
            repaired=$(( repaired + 1 ))
        else
            _warn "Cannot restart daemons: boot script missing. Run 'fresh-phone' or 'doctor'."
        fi
    fi

    # `|| true` retained from the original `&& ... || true`: this is the last
    # statement of the function under `set -e`, so a failed write to stderr
    # would otherwise abort the caller.
    if [[ ${repaired} -gt 0 ]]; then
        _info "Minor repairs applied: ${repaired}" || true
    fi
}

# A rooted backup is small and runs every time. An unrooted one copies all of
# shared storage, so it runs at most once per BACKUP_AUTO_INTERVAL_SECS. The
# attempt is marked BEFORE it runs: a backup that keeps failing verification
# must not re-pull 1.3 GB every 30 minutes; its FATAL is in the journal.
_auto_backup() {
    local device_id="$1"

    if [[ "${ADB_HAS_ROOT:-1}" == "1" ]]; then
        backup_run_incremental "${device_id}"
    elif adb_check_cooldown "${BACKUP_AUTO_INTERVAL_SECS}" "backup_${device_id}"; then
        adb_mark_last_run "backup_${device_id}"
        backup_run_incremental "${device_id}"
    else
        _info "auto: backup throttled (unrooted backup runs at most once per ${BACKUP_AUTO_INTERVAL_SECS}s; run 'backup' to force one)"
    fi
}

cmd_auto() {
    adb_acquire_lock

    if ! adb_check_cooldown "${COOLDOWN_AUTO_SECS}" "auto"; then
        _info "auto: cooldown active, nothing to do."
        exit 0
    fi

    # Unattended (phone-auto-sync.timer): act only on an enrolled phone, rooted
    # or not. An explicit ADB_SERIAL keeps the interactive fail-loudly behaviour.
    if [[ -z "${ADB_SERIAL:-}" ]] && ! ADB_SERIAL="$(adb_find_auto_target)"; then
        _info "auto: no enrolled phone connected ($(adb_list_ready_serials | tr '\n' ' ')); nothing to do."
        exit 0
    fi
    export ADB_SERIAL

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
    _auto_backup "${device_id}"
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
    adb_mark_last_run "backup_${device_id}"
    backup_run_incremental "${device_id}"
}

# Enrolment without root: records serial, model and build fingerprint on the
# PC. Before this, fresh-phone (root-only) was the only enroller, so an
# unrooted phone could never become an `auto` target.
cmd_enroll() {
    adb_select_device "${ADB_SERIAL:-}"
    adb_save_trusted_device
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

case "${SUBCOMMAND}" in
    auto)        cmd_auto ;;
    enroll)      cmd_enroll ;;
    fresh-phone) cmd_fresh_phone ;;
    backup)      cmd_backup ;;
    monitor)     cmd_monitor ;;
    doctor)      cmd_doctor ;;
esac
