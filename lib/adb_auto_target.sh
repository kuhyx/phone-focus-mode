#!/usr/bin/env bash
# lib/adb_auto_target.sh — pick the phone an UNATTENDED run may act on.
# Sourced by adb_common.sh; do not execute directly. Uses adb_list_trusted_serials
# and _load_trusted_device_values from adb_trusted.sh / adb_common.sh.
#
# Why this exists: `run_phone.sh auto` runs from phone-auto-sync.timer every
# 30 minutes, whether or not the rooted phone is plugged in. Interactive
# selection (adb_select_device) is right for a person at a terminal -- it
# auto-picks the only connected device and dies if that device lacks root.
# For a timer that turned "the Pixel 6a is charging on the desk" into a FATAL
# every half hour, and "nothing connected" into another. Unattended, the only
# correct outcome when no enrolled rooted phone is present is "nothing to do".
#
# Every probe here is read-only: `adb devices` and an `echo ok` through su.

# Serials adb reports as fully usable ("device"); offline/unauthorized phones
# cannot be acted on, so they are not candidates.
adb_list_ready_serials() {
	adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}

# Enrolled serials: one per per-device record, plus the legacy single record.
_auto_trusted_serials() {
	adb_list_trusted_serials
	if _load_trusted_device_values "${TRUSTED_DEVICE_FILE}" 2>/dev/null; then
		[[ -n "${TRUSTED_SERIAL_LOADED:-}" ]] && printf '%s\n' "${TRUSTED_SERIAL_LOADED}"
	fi
	return 0
}

_auto_has_root() {
	local result=""
	result="$(adb -s "$1" shell su --mount-master -c "echo ok" 2>/dev/null | tr -d '\r' || true)"
	[[ "${result}" == "ok" ]]
}

# Prints the first connected serial that is both enrolled and rooted, and
# returns 0; returns 1 (printing nothing) when there is none. The full identity
# check (model + build fingerprint) still runs afterwards in
# adb_verify_trusted_identity -- matching the serial here only narrows the
# candidates, it does not vouch for the device.
adb_find_auto_target() {
	local serial=""
	local -a ready=() trusted=()

	mapfile -t ready < <(adb_list_ready_serials)
	mapfile -t trusted < <(_auto_trusted_serials)

	for serial in "${ready[@]}"; do
		printf '%s\n' "${trusted[@]}" | grep -qxF -- "${serial}" || continue
		_auto_has_root "${serial}" || continue
		printf '%s\n' "${serial}"
		return 0
	done
	return 1
}
