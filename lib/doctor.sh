#!/usr/bin/env bash
# lib/doctor.sh — `run_phone.sh doctor`: diagnose and repair security drift
# without a data restore. Root only: every repair is a root-shell write, so an
# unrooted phone stops at adb_verify_root.
#
# Sourced by run_phone.sh, which defines _setup_common and sources adb_common,
# monitor and restore before calling cmd_doctor.

cmd_doctor() {
    _setup_common
    # Every repair is a root-shell write.
    adb_verify_root
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
