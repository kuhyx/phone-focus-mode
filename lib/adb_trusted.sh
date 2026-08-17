#!/usr/bin/env bash
# lib/adb_trusted.sh — the enrolled-device record: saving, listing, forgetting,
# and refusing to act on a phone that is not enrolled.
# Sourced by adb_common.sh; do not execute directly, and do not source it on
# its own: it uses TRUSTED_DEVICE_DIR/TRUSTED_DEVICE_FILE, the DEVICE_* vars and
# the _info/_warn/_error/_fatal helpers that adb_common.sh defines first.

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

	# Passed explicitly rather than shadowing the global, so a per-record value
	# cannot change which file later callers read.
	if ! _load_trusted_device_values "${record}"; then
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
