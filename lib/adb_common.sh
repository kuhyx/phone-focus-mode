#!/usr/bin/env bash
# lib/adb_common.sh — ADB device selection, identity, and root helpers.
# Source this file; do not execute directly.
set -euo pipefail

_PHONE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phone_focus_mode"
TRUSTED_DEVICE_FILE="${_PHONE_STATE_DIR}/trusted_device.sh"
LOCK_DIR="${_PHONE_STATE_DIR}/locks"
LAST_RUN_DIR="${_PHONE_STATE_DIR}/last_run"
LOCK_FILE=""

_info() {
    printf '\033[0;34m[INFO]\033[0m  %s\n' "$*" >&2
}

_warn() {
    printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2
}

_error() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
}

_fatal() {
    printf '\033[0;31m[FATAL]\033[0m %s\n' "$*" >&2
    exit 1
}

_box() {
    local title="$1"
    shift

    printf '\n\033[1;33m╔══════════════════════════════════════════╗\033[0m\n' >&2
    printf '\033[1;33m║  %-42s║\033[0m\n' "${title}" >&2
    printf '\033[1;33m╚══════════════════════════════════════════╝\033[0m\n' >&2
    for line in "$@"; do
        printf '  %s\n' "${line}" >&2
    done
}

adb_list_serials() {
    adb devices 2>/dev/null |
        awk 'NR > 1 && $2 ~ /^(device|offline|unauthorized)$/ { print $1 }'
}

_load_trusted_device_values() {
    local file_path="${1:-${TRUSTED_DEVICE_FILE}}"
    local -a loaded_values=()

    [[ -f "${file_path}" ]] || return 1

    if ! mapfile -t loaded_values < <(
        bash -c '
            set -euo pipefail
            source "$1"
            printf "%s\n" "${TRUSTED_SERIAL:-}" "${TRUSTED_MODEL:-}" "${TRUSTED_FINGERPRINT:-}"
        ' bash "${file_path}"
    ); then
        _warn "Trusted device record is unreadable: ${file_path}"
        return 1
    fi

    TRUSTED_SERIAL_LOADED="${loaded_values[0]:-}"
    TRUSTED_MODEL_LOADED="${loaded_values[1]:-}"
    TRUSTED_FINGERPRINT_LOADED="${loaded_values[2]:-}"
    export TRUSTED_SERIAL_LOADED TRUSTED_MODEL_LOADED TRUSTED_FINGERPRINT_LOADED
}

adb_select_device() {
    local requested="${1:-${ADB_SERIAL:-}}"
    local found=0
    local serial=""
    local -a serials=()

    mapfile -t serials < <(adb_list_serials)

    if [[ ${#serials[@]} -eq 0 ]]; then
        _fatal "No ADB device found. Connect via USB or pair wireless ADB first."
    fi

    if [[ -n "${requested}" ]]; then
        for serial in "${serials[@]}"; do
            if [[ "${serial}" == "${requested}" ]]; then
                found=1
                break
            fi
        done

        if [[ "${found}" -ne 1 ]]; then
            _fatal "Requested device '${requested}' not found. Connected: ${serials[*]}"
        fi

        export ADB_SERIAL="${requested}"
        return 0
    fi

    if [[ ${#serials[@]} -eq 1 ]]; then
        export ADB_SERIAL="${serials[0]}"
        _info "Auto-selected device: ${ADB_SERIAL}"
        return 0
    fi

    _fatal "Multiple ADB devices found (${serials[*]}) and no target specified. Use --serial or set ADB_SERIAL."
}

adb_cmd() {
    adb -s "${ADB_SERIAL:?adb_select_device must be called first}" "$@"
}

adb_verify_root() {
    local result=""

    result="$(adb_cmd shell su --mount-master -c "echo ok" 2>/dev/null || true)"
    if [[ "${result}" != "ok" ]]; then
        _fatal "Root check failed on ${ADB_SERIAL}. Ensure Magisk is installed and ADB root is authorized."
    fi

    _info "Root verified on ${ADB_SERIAL}"
}

adb_root_shell() {
    local command_text="$*"

    printf '%s\n' "${command_text}" | adb_cmd shell su --mount-master -c "sh -s"
}

_sanitize_device_string() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._:/-'
}

adb_collect_identity() {
    local raw_fingerprint=""
    local raw_model=""

    raw_model="$(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    raw_fingerprint="$(adb_cmd shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"

    DEVICE_MODEL="$(_sanitize_device_string "${raw_model}")"
    DEVICE_FINGERPRINT="$(_sanitize_device_string "${raw_fingerprint}")"
    DEVICE_SERIAL="$(_sanitize_device_string "${ADB_SERIAL}")"
    export DEVICE_MODEL DEVICE_FINGERPRINT DEVICE_SERIAL
}

adb_save_trusted_device() {
    adb_collect_identity
    mkdir -p "${_PHONE_STATE_DIR}"

    {
        printf '# Auto-generated trusted device record — do not edit manually.\n'
        printf 'TRUSTED_SERIAL=%q\n' "${DEVICE_SERIAL}"
        printf 'TRUSTED_MODEL=%q\n' "${DEVICE_MODEL}"
        printf 'TRUSTED_FINGERPRINT=%q\n' "${DEVICE_FINGERPRINT}"
    } >"${TRUSTED_DEVICE_FILE}"

    chmod 600 "${TRUSTED_DEVICE_FILE}"
    _info "Saved trusted device record: model='${DEVICE_MODEL}' serial='${DEVICE_SERIAL}'"
}

adb_verify_trusted_identity() {
    local saved_model=""
    local saved_fingerprint=""
    local saved_serial=""

    if [[ ! -f "${TRUSTED_DEVICE_FILE}" ]]; then
        _warn "No trusted device record found. Run 'fresh-phone' to enroll this device."
        return 0
    fi

    if ! _load_trusted_device_values; then
        _fatal "Trusted device record exists but could not be read: ${TRUSTED_DEVICE_FILE}"
    fi

    saved_serial="${TRUSTED_SERIAL_LOADED:-}"
    saved_model="${TRUSTED_MODEL_LOADED:-}"
    saved_fingerprint="${TRUSTED_FINGERPRINT_LOADED:-}"
    adb_collect_identity

    if [[ -n "${saved_serial}" && "${DEVICE_SERIAL}" != "${saved_serial}" ]]; then
        _fatal "Device identity mismatch: expected serial '${saved_serial}', got '${DEVICE_SERIAL}'. Refusing to proceed automatically."
    fi

    if [[ -n "${saved_model}" && "${DEVICE_MODEL}" != "${saved_model}" ]]; then
        _fatal "Device identity mismatch: expected model '${saved_model}', got '${DEVICE_MODEL}'. Refusing to proceed automatically."
    fi

    if [[ -n "${saved_fingerprint}" && "${DEVICE_FINGERPRINT}" != "${saved_fingerprint}" ]]; then
        _fatal "Device identity mismatch: expected fingerprint '${saved_fingerprint}', got '${DEVICE_FINGERPRINT}'. Refusing to proceed automatically."
    fi

    _info "Device identity verified: ${DEVICE_SERIAL} (${DEVICE_MODEL})"
}

_adb_release_lock() {
    if [[ -n "${LOCK_FILE}" && -d "${LOCK_FILE}" ]]; then
        rm -rf "${LOCK_FILE}"
    fi
}

adb_acquire_lock() {
    local lock_pid_file=""
    local old_pid=""

    mkdir -p "${LOCK_DIR}"
    LOCK_FILE="${LOCK_DIR}/run_phone.lock"
    lock_pid_file="${LOCK_FILE}/pid"

    if mkdir "${LOCK_FILE}" 2>/dev/null; then
        printf '%s\n' "$$" >"${lock_pid_file}"
        trap _adb_release_lock EXIT INT TERM
        _info "Acquired run lock (PID $$)"
        return 0
    fi

    old_pid="$(cat "${lock_pid_file}" 2>/dev/null || printf '')"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        _fatal "Another run_phone.sh instance is already running (PID ${old_pid}). Aborting."
    fi

    _warn "Stale lock directory found (PID ${old_pid} no longer running). Removing."
    rm -rf "${LOCK_FILE}"

    if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
        _fatal "Could not acquire run lock at ${LOCK_FILE}. Another process may have raced us."
    fi

    printf '%s\n' "$$" >"${lock_pid_file}"
    trap _adb_release_lock EXIT INT TERM
    _info "Acquired run lock (PID $$)"
}

adb_check_cooldown() {
    local cooldown_secs="${1:-300}"
    local elapsed=0
    local last_run=0
    local marker_name="${2:-default}"
    local marker="${LAST_RUN_DIR}/${marker_name}"
    local now=0

    mkdir -p "${LAST_RUN_DIR}"
    if [[ -f "${marker}" ]]; then
        last_run="$(cat "${marker}")"
        if [[ "${last_run}" =~ ^[0-9]+$ ]]; then
            now="$(date +%s)"
            elapsed=$((now - last_run))
            if ((elapsed < cooldown_secs)); then
                _info "Cooldown active: last run ${elapsed}s ago, cooldown is ${cooldown_secs}s. Skipping."
                return 1
            fi
        else
            _warn "Ignoring invalid cooldown marker: ${marker}"
        fi
    fi

    return 0
}

adb_mark_last_run() {
    local marker_name="${1:-default}"

    mkdir -p "${LAST_RUN_DIR}"
    date +%s >"${LAST_RUN_DIR}/${marker_name}"
}
