#!/usr/bin/env bash
# lib/adb_common.sh — ADB device selection, identity, and root helpers.
# Source this file; do not execute directly.
set -euo pipefail

_PHONE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phone_focus_mode"
TRUSTED_DEVICE_FILE="${_PHONE_STATE_DIR}/trusted_device.sh"
# One file per enrolled device, so a second phone does not evict the first.
# The legacy single-device record above is still honoured when present.
TRUSTED_DEVICE_DIR="${_PHONE_STATE_DIR}/trusted_devices"
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

# Reads one enrolled-device record into TRUSTED_*_LOADED.
# Takes the path explicitly, defaulting to the legacy single-device record.
# Callers that need a specific record pass it rather than shadowing the global,
# which kept the value from leaking into later calls without relying on a
# `local` of a name declared in another file.
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

# The enrolled-device record. Sourced from this file's own directory so every
# existing consumer keeps getting the whole API from one source line.
# shellcheck source=adb_trusted.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb_trusted.sh"

# Run lock and cooldown helpers. Sourced last, from this file's own directory,
# so every existing consumer keeps getting the whole API from one source line.
# shellcheck source=adb_locking.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb_locking.sh"
