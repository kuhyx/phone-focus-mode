#!/usr/bin/env bash
# lib/backup.sh — Incremental backup of APKs, app data, media, and security state.
# Requires: adb_common.sh and backup_manifest.sh sourced, ADB_SERIAL set.
set -euo pipefail

readonly _BACKUP_REMOTE_DIR="/data/local/tmp/focus_mode"

_backup_validate_package_name() {
    local package_name="$1"

    [[ "${package_name}" =~ ^[A-Za-z0-9._-]+$ ]] || _fatal "Unsafe package name rejected: ${package_name}"
}

backup_make_snapshot_dir() {
    local device_id="$1"
    local timestamp=""
    local snapshot_dir=""

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    snapshot_dir="${PHONE_BACKUP_ROOT}/${device_id}/history/${timestamp}"
    mkdir -p \
        "${snapshot_dir}/device_info" \
        "${snapshot_dir}/security_state" \
        "${snapshot_dir}/apks" \
        "${snapshot_dir}/app_data" \
        "${snapshot_dir}/media" \
        "${snapshot_dir}/monitoring"
    printf '%s' "${snapshot_dir}"
}

_backup_update_latest() {
    local snapshot_dir="$1"
    local device_root="$2"
    local latest_dir="${device_root}/latest"

    rm -rf "${latest_dir}"
    if ln -s "${snapshot_dir}" "${latest_dir}" 2>/dev/null; then
        return 0
    fi

    mkdir -p "${latest_dir}"
    cp -a "${snapshot_dir}/." "${latest_dir}/"
}

backup_device_info() {
    local output_dir="$1/device_info"

    _info "Backing up device info → ${output_dir}"
    adb_cmd shell getprop >"${output_dir}/getprop.txt" 2>/dev/null || true
    adb_cmd shell pm list packages -f >"${output_dir}/packages_full.txt" 2>/dev/null || true
    adb_cmd shell pm list packages >"${output_dir}/packages.txt" 2>/dev/null || true
    adb_cmd shell df >"${output_dir}/df.txt" 2>/dev/null || true
    printf '%s\n' "${ADB_SERIAL}" >"${output_dir}/serial.txt"
    adb_cmd shell getprop ro.product.model >"${output_dir}/model.txt" 2>/dev/null || true
    adb_cmd shell getprop ro.build.fingerprint >"${output_dir}/fingerprint.txt" 2>/dev/null || true
}

backup_security_state() {
    local output_dir="$1/security_state"
    local source_path=""
    local destination_dir=""

    _info "Backing up security state → ${output_dir}"

    for source_path in "${SECURITY_STATE_FILES[@]}"; do
        destination_dir="${output_dir}$(dirname "${source_path}")"
        mkdir -p "${destination_dir}"
        adb_root_shell "cat '${source_path}'" >"${destination_dir}/$(basename "${source_path}")" 2>/dev/null || \
            _warn "Could not back up ${source_path} (may not exist yet)"
    done

    adb_root_shell "sh '${_BACKUP_REMOTE_DIR}/focus_ctl.sh' status" >"${output_dir}/focus_status.txt" 2>/dev/null || true
    adb_root_shell "sh '${_BACKUP_REMOTE_DIR}/focus_ctl.sh' hosts-status" >"${output_dir}/hosts_status.txt" 2>/dev/null || true
    adb_root_shell "sh '${_BACKUP_REMOTE_DIR}/focus_ctl.sh' dns-status" >"${output_dir}/dns_status.txt" 2>/dev/null || true
    adb_root_shell "sh '${_BACKUP_REMOTE_DIR}/focus_ctl.sh' launcher-status" >"${output_dir}/launcher_status.txt" 2>/dev/null || true
    adb_root_shell "sh '${_BACKUP_REMOTE_DIR}/focus_ctl.sh' notif-status" >"${output_dir}/notif_status.txt" 2>/dev/null || true
    adb_root_shell "settings get global private_dns_mode" >"${output_dir}/private_dns_mode.txt" 2>/dev/null || true
}

backup_apks() {
    local output_dir="$1/apks"
    local entry=""
    local package_name=""
    local restore_policy=""
    local apk_path=""
    local destination_dir=""

    _info "Backing up APKs → ${output_dir}"

    for entry in "${APK_ITEMS[@]}"; do
        package_name="${entry%%|*}"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        _backup_validate_package_name "${package_name}"

        apk_path="$(adb_cmd shell "pm path ${package_name} | head -1 | sed 's/^package://'" 2>/dev/null | tr -d '\r' || true)"
        if [[ -z "${apk_path}" ]]; then
            _warn "APK not found on device: ${package_name}"
            continue
        fi

        destination_dir="${output_dir}/${package_name}"
        mkdir -p "${destination_dir}"
        if adb_cmd pull "${apk_path}" "${destination_dir}/base.apk" >/dev/null 2>&1; then
            _info "  Backed up ${package_name} (policy: ${restore_policy})"
        else
            _warn "  Failed to pull APK for ${package_name}"
        fi
        printf '%s\n' "${restore_policy}" >"${destination_dir}/restore_policy.txt"
        if [[ "${restore_policy}" == "manual_only" ]]; then
            printf '%s\n' 'NOTE: manual_only — restore requires explicit operator action' >>"${destination_dir}/restore_policy.txt"
        elif [[ "${restore_policy}" == "backup_only" ]]; then
            printf '%s\n' 'NOTE: backup_only — backed up for safekeeping; automated restore is not implemented' >>"${destination_dir}/restore_policy.txt"
        fi
    done
}

backup_app_data() {
    local output_dir="$1/app_data"
    local entry=""
    local package_name=""
    local data_path=""
    local restore_policy=""
    local destination_dir=""
    local parent_dir=""
    local base_dir=""
    local tar_command=""

    _info "Backing up app data → ${output_dir}"

    for entry in "${APP_DATA_ITEMS[@]}"; do
        package_name="${entry%%|*}"
        data_path="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f3)"
        _backup_validate_package_name "${package_name}"

        destination_dir="${output_dir}/${package_name}"
        mkdir -p "${destination_dir}"

        if ! adb_root_shell "test -d '${data_path}'" >/dev/null 2>&1; then
            _warn "App data path not found: ${data_path} for ${package_name}"
            continue
        fi

        parent_dir="$(dirname "${data_path}")"
        base_dir="$(basename "${data_path}")"
        tar_command="tar -czf - -C '${parent_dir}' '${base_dir}'"
        if adb_root_shell "${tar_command}" >"${destination_dir}/data.tar.gz" 2>/dev/null; then
            _info "  Backed up app data for ${package_name} (policy: ${restore_policy})"
        else
            _warn "  Failed to back up app data for ${package_name}"
        fi

        printf '%s\n' "${restore_policy}" >"${destination_dir}/restore_policy.txt"
        if [[ "${restore_policy}" == "manual_only" ]]; then
            printf '%s\n' 'NOTE: manual_only — restore requires explicit operator action' >>"${destination_dir}/restore_policy.txt"
        elif [[ "${restore_policy}" == "backup_only" ]]; then
            printf '%s\n' 'NOTE: backup_only — backed up for safekeeping; automated restore is not implemented' >>"${destination_dir}/restore_policy.txt"
        fi
    done
}

backup_media() {
    local output_dir="$1/media"
    local entry=""
    local name=""
    local on_device_path=""
    local restore_policy=""
    local destination_dir=""

    _info "Backing up media → ${output_dir}"

    for entry in "${MEDIA_ITEMS[@]}"; do
        name="${entry%%|*}"
        on_device_path="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f3)"
        destination_dir="${output_dir}/${name}"
        mkdir -p "${destination_dir}"

        if adb_cmd pull "${on_device_path}" "${destination_dir}/" >/dev/null 2>&1; then
            _info "  Backed up media/${name} from ${on_device_path} (policy: ${restore_policy})"
        else
            _warn "  Could not pull media/${name} from ${on_device_path}"
        fi
        printf '%s\n' "${restore_policy}" >"${destination_dir}/restore_policy.txt"
        if [[ "${restore_policy}" == "manual_only" ]]; then
            printf '%s\n' 'NOTE: manual_only — restore requires explicit operator action' >>"${destination_dir}/restore_policy.txt"
        elif [[ "${restore_policy}" == "backup_only" ]]; then
            printf '%s\n' 'NOTE: backup_only — backed up for safekeeping; automated restore is not implemented' >>"${destination_dir}/restore_policy.txt"
        fi
    done
}

backup_prune_history() {
    local device_root="$1"
    local history_dir="${device_root}/history"

    [[ -d "${history_dir}" ]] || return 0
    _info "Pruning history older than ${HISTORY_KEEP_DAYS} days in ${history_dir}"
    find "${history_dir}" -maxdepth 1 -mindepth 1 -type d -mtime "+${HISTORY_KEEP_DAYS}" -print -exec rm -rf '{}' + || true
}

backup_run_incremental() {
    local device_id="$1"
    local device_root="${PHONE_BACKUP_ROOT}/${device_id}"
    local snapshot_dir=""

    snapshot_dir="$(backup_make_snapshot_dir "${device_id}")"
    _info "Starting incremental backup to ${snapshot_dir}"

    backup_device_info "${snapshot_dir}"
    backup_security_state "${snapshot_dir}"
    backup_apks "${snapshot_dir}"
    backup_app_data "${snapshot_dir}"
    backup_media "${snapshot_dir}"
    _backup_update_latest "${snapshot_dir}" "${device_root}"
    backup_prune_history "${device_root}"

    _info "Backup complete: ${snapshot_dir}"
    printf '%s' "${snapshot_dir}"
}
