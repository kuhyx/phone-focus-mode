#!/usr/bin/env bash
# lib/adb_auto_target.sh — pick the phone an UNATTENDED run may act on.
# Sourced by adb_common.sh; do not execute directly. Uses adb_list_trusted_serials
# and _load_trusted_device_values from adb_trusted.sh / adb_common.sh.
#
# Why this exists: `run_phone.sh auto` runs from phone-auto-sync.timer every
# 30 minutes, whether or not a phone is plugged in. Interactive selection
# (adb_select_device) is right for a person at a terminal -- it auto-picks the
# only connected device and dies when there is none. For a timer that turned
# "nothing connected" into a FATAL every half hour. Unattended, the only
# correct outcome when no enrolled phone is present is "nothing to do".
#
# Root is NOT required: the Pixel 6a is stock and stays unrooted, and auto
# runs the read-only unrooted mode on it. A rooted enrolled phone still wins
# when both are connected, since it gets the fuller check set.
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

# Prints the first connected enrolled serial -- a rooted one if any, else the
# first unrooted one -- and returns 0; returns 1 (printing nothing) when no
# enrolled phone is connected. The full identity
# check (model + build fingerprint) still runs afterwards in
# adb_verify_trusted_identity -- matching the serial here only narrows the
# candidates, it does not vouch for the device.
adb_find_auto_target() {
	local serial="" unrooted=""
	local -a ready=() trusted=()

	mapfile -t ready < <(adb_list_ready_serials)
	mapfile -t trusted < <(_auto_trusted_serials)

	for serial in "${ready[@]}"; do
		printf '%s\n' "${trusted[@]}" | grep -qxF -- "${serial}" || continue
		if _auto_has_root "${serial}"; then
			printf '%s\n' "${serial}"
			return 0
		fi
		[[ -n "${unrooted}" ]] || unrooted="${serial}"
	done
	[[ -n "${unrooted}" ]] || return 1
	printf '%s\n' "${unrooted}"
}
