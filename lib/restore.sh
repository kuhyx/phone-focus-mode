#!/usr/bin/env bash
# lib/restore.sh — Restore security stack, APKs, and media after format.
# Requires: adb_common.sh, backup_manifest.sh sourced, ADB_SERIAL set.
set -euo pipefail

_RESTORE_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly _RESTORE_PROJECT_DIR

_restore_validate_package_name() {
    local package_name="$1"

    [[ "${package_name}" =~ ^[A-Za-z0-9._-]+$ ]] || _fatal "Unsafe package name rejected: ${package_name}"
}

restore_verify_prerequisites() {
    local -a problems=()

    if ! adb_cmd get-state >/dev/null 2>&1; then
        problems+=("ADB device not reachable. Ensure USB debugging is authorized or wireless ADB is paired.")
    fi

    if ! adb_root_shell "echo root_ok" 2>/dev/null | grep -q '^root_ok$'; then
        problems+=("Root shell failed. Ensure Magisk is installed and ADB root is authorized in Magisk settings.")
    fi

    if ! adb_root_shell "test -d /data/adb && command -v magisk >/dev/null 2>&1" >/dev/null 2>&1; then
        problems+=("Magisk runtime not detected. Install Magisk and verify rooted debugging is enabled.")
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        _box "PREREQUISITES NOT MET — CANNOT CONTINUE" \
            "" \
            "Please resolve the following before running fresh-phone:" \
            "${problems[@]/#/  ✗ }" \
            "" \
            "Manual steps for a freshly formatted phone:" \
            "  1. Install Magisk from https://github.com/topjohnwu/Magisk" \
            "  2. In Magisk → Settings → enable 'Rooted Debugging'" \
            "  3. On phone: Settings → Developer options → enable 'USB Debugging'" \
            "  4. Authorize this PC on the phone when prompted" \
            "  5. Pair wireless ADB again if you normally use it"
        return 1
    fi

    _info "All restore prerequisites verified"
}

restore_security_stack() {
    local deploy_script="${_RESTORE_PROJECT_DIR}/deploy.sh"

    _info "Restoring security stack via deploy.sh"
    [[ -x "${deploy_script}" ]] || _fatal "deploy.sh not found or not executable at ${deploy_script}"
    env ADB_SERIAL="${ADB_SERIAL}" PHONE_IP="${PHONE_IP:-}" bash "${deploy_script}" "${PHONE_IP:-}"
}

restore_apks() {
    local backup_dir="$1"
    local apk_dir="${backup_dir}/apks"
    local entry=""
    local package_name=""
    local restore_policy=""
    local apk_path=""

    [[ -d "${apk_dir}" ]] || {
        _warn "No APK backup found at ${apk_dir}"
        return 0
    }

    _info "Restoring APKs from ${apk_dir}"
    for entry in "${APK_ITEMS[@]}"; do
        package_name="${entry%%|*}"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        _restore_validate_package_name "${package_name}"

        if [[ "${restore_policy}" != "safe_restore" ]]; then
            _info "  Skipping ${package_name} (policy: ${restore_policy})"
            continue
        fi

        apk_path="${apk_dir}/${package_name}/base.apk"
        if [[ ! -f "${apk_path}" ]]; then
            _warn "  APK not found in backup: ${package_name}"
            continue
        fi

        if adb_cmd install -r "${apk_path}" >/dev/null 2>&1; then
            _info "  Installed ${package_name}"
        else
            _warn "  Failed to install ${package_name}"
        fi
    done
}

restore_media() {
    local backup_dir="$1"
    local media_dir="${backup_dir}/media"
    local entry=""
    local name=""
    local on_device_path=""
    local restore_policy=""
    local source_dir=""

    [[ -d "${media_dir}" ]] || {
        _warn "No media backup found at ${media_dir}"
        return 0
    }

    _info "Restoring media from ${media_dir}"
    for entry in "${MEDIA_ITEMS[@]}"; do
        name="${entry%%|*}"
        on_device_path="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f3)"

        if [[ "${restore_policy}" != "safe_restore" ]]; then
            _info "  Skipping media/${name} (policy: ${restore_policy})"
            continue
        fi

        source_dir="${media_dir}/${name}"
        if [[ ! -d "${source_dir}" ]]; then
            _warn "  Media backup not found: ${source_dir}"
            continue
        fi

        if adb_cmd push "${source_dir}/." "${on_device_path}/" >/dev/null 2>&1; then
            _info "  Restored media/${name}"
        else
            _warn "  Failed to restore media/${name}"
        fi
    done
}

restore_print_manual_steps() {
    local backup_dir="$1"
    local -a steps=()
    local entry=""
    local package_name=""
    local data_path=""
    local restore_policy=""

    for entry in "${APP_DATA_ITEMS[@]}"; do
        package_name="${entry%%|*}"
        data_path="$(printf '%s' "${entry}" | cut -d'|' -f2)"
        restore_policy="$(printf '%s' "${entry}" | cut -d'|' -f3)"
        _restore_validate_package_name "${package_name}"

        if [[ "${restore_policy}" == "manual_only" ]]; then
            steps+=("App data for ${package_name}: backup at ${backup_dir}/app_data/${package_name}/data.tar.gz (source ${data_path})")
        fi
    done

    steps+=("Re-enter coordinates in phone_focus_mode/config_secrets.sh if needed")
    steps+=("Re-authorize wireless ADB pairing if you use it")
    steps+=("Verify Magisk modules are re-installed if any were previously in use")

    if [[ ${#steps[@]} -gt 0 ]]; then
        _box "MANUAL FOLLOW-UP STEPS REQUIRED" \
            "" \
            "The automated restore is complete. You must handle the following manually:" \
            "${steps[@]/#/  ▶ }"
    fi
}
