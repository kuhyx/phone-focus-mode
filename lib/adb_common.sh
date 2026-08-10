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

_load_trusted_device_values() {
	local file_path="${TRUSTED_DEVICE_FILE}"
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

ADB_ENROLLED_DEVICE_FILE=""

# Path of the per-device record for a serial. Serials are sanitised to
# [A-Za-z0-9._-] by _sanitize_device_string, so this cannot escape the dir.
_trusted_device_path() {
	printf '%s/%s.sh' "${TRUSTED_DEVICE_DIR}" "$1"
}

adb_save_trusted_device() {
	local record=""

	adb_collect_identity
	mkdir -p "${TRUSTED_DEVICE_DIR}"
	chmod 700 "${TRUSTED_DEVICE_DIR}"
	record="$(_trusted_device_path "${DEVICE_SERIAL}")"

	{
		printf '# Auto-generated trusted device record — do not edit manually.\n'
		printf 'TRUSTED_SERIAL=%q\n' "${DEVICE_SERIAL}"
		printf 'TRUSTED_MODEL=%q\n' "${DEVICE_MODEL}"
		printf 'TRUSTED_FINGERPRINT=%q\n' "${DEVICE_FINGERPRINT}"
	} >"${record}"

	chmod 600 "${record}"
	ADB_ENROLLED_DEVICE_FILE="${record}"
	export ADB_ENROLLED_DEVICE_FILE
	_info "Enrolled device: model='${DEVICE_MODEL}' serial='${DEVICE_SERIAL}'"
}

# Serials with a per-device record, newest first is not meaningful here so
# the order is whatever the glob yields.
adb_list_trusted_serials() {
	local record=""
	[[ -d "${TRUSTED_DEVICE_DIR}" ]] || return 0
	for record in "${TRUSTED_DEVICE_DIR}"/*.sh; do
		[[ -e "${record}" ]] || continue
		basename "${record}" .sh
	done
}

adb_forget_trusted_device() {
	local serial="${1:?serial required}"
	local record=""
	record="$(_trusted_device_path "$(_sanitize_device_string "${serial}")")"
	if [[ -f "${record}" ]]; then
		rm -f "${record}"
		_info "Removed trusted device record for '${serial}'"
	else
		_warn "No trusted device record for '${serial}'"
	fi
}

# Compares the connected device against one record. Returns 0 on a match,
# 1 when the record is for a different device, and 2 when the record names
# this serial but its model or fingerprint has changed -- which is the case
# worth shouting about, since a serial is the easiest field to spoof and a
# changed fingerprint means the device was reflashed.
_matches_trusted_record() {
	local record="${1:?record required}"
	local saved_serial="" saved_model="" saved_fingerprint=""
	# Scoped to this call: _load_trusted_device_values reads the global, and
	# leaking a per-record value would change which file later callers use.
	local TRUSTED_DEVICE_FILE="${record}"

	if ! _load_trusted_device_values; then
		_fatal "Trusted device record exists but could not be read: ${record}"
	fi

	saved_serial="${TRUSTED_SERIAL_LOADED:-}"
	saved_model="${TRUSTED_MODEL_LOADED:-}"
	saved_fingerprint="${TRUSTED_FINGERPRINT_LOADED:-}"

	[[ -n "${saved_serial}" && "${DEVICE_SERIAL}" != "${saved_serial}" ]] && return 1

	if [[ -n "${saved_model}" && "${DEVICE_MODEL}" != "${saved_model}" ]]; then
		_error "Device '${DEVICE_SERIAL}' is enrolled but its model changed: expected '${saved_model}', got '${DEVICE_MODEL}'."
		return 2
	fi

	if [[ -n "${saved_fingerprint}" && "${DEVICE_FINGERPRINT}" != "${saved_fingerprint}" ]]; then
		_error "Device '${DEVICE_SERIAL}' is enrolled but its build fingerprint changed."
		_error "  expected: ${saved_fingerprint}"
		_error "  got:      ${DEVICE_FINGERPRINT}"
		return 2
	fi

	return 0
}

# Fails closed: an unknown device aborts. Any ENROLLED device is accepted,
# so several phones can be managed from one PC without re-enrolling on
# every switch. Only a completely empty store is permissive, and that is
# the first-run case where there is nothing yet to contradict.
adb_verify_trusted_identity() {
	local record="" rc=0
	local -a records=()

	if [[ -d "${TRUSTED_DEVICE_DIR}" ]]; then
		for record in "${TRUSTED_DEVICE_DIR}"/*.sh; do
			[[ -e "${record}" ]] && records+=("${record}")
		done
	fi
	# Legacy single-device record stays authoritative until it is migrated,
	# so an existing install keeps its guarantee without any manual step.
	[[ -f "${_PHONE_STATE_DIR}/trusted_device.sh" ]] &&
		records+=("${_PHONE_STATE_DIR}/trusted_device.sh")

	if [[ ${#records[@]} -eq 0 ]]; then
		_warn "No trusted device record found. Run 'fresh-phone' to enroll this device."
		return 0
	fi

	adb_collect_identity

	for record in "${records[@]}"; do
		_matches_trusted_record "${record}" && {
			_info "Device identity verified: ${DEVICE_SERIAL} (${DEVICE_MODEL})"
			return 0
		}
		rc=$?
		# A tampered/reflashed match must abort rather than fall through to
		# the next record, which would silently downgrade the check.
		[[ "${rc}" -eq 2 ]] && _fatal "Refusing to proceed automatically."
	done

	_error "Device '${DEVICE_SERIAL}' (${DEVICE_MODEL}) is not enrolled."
	_error "Enrolled: $(adb_list_trusted_serials | tr '\n' ' ')"
	_fatal "Refusing to proceed automatically. Enroll it first if this is expected."
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
