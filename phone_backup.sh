#!/usr/bin/env bash
# ============================================================
# Phone backup — everything ADB can reach on an UNROOTED device
#
# READ THIS FIRST. This is NOT a full-device backup and cannot
# be one. Restoring from it does NOT give you the phone back as
# it was; it gives you your FILES back and a checklist of what
# to reinstall and re-authenticate by hand.
#
# What it captures:
#   - every installed package name, split into system/third-party
#   - the APK of every third-party app (so you can reinstall
#     offline, including F-Droid apps that may have moved on)
#   - /sdcard user data: DCIM, Pictures, Download, Documents,
#     Movies, Music, plus Signal backups if present
#   - settings (system/secure/global), which covers most of the
#     phone's own configuration
#   - the focus-mode state: which packages are purged, and the
#     RethinkDNS domain rules if its export is present
#
# What it CANNOT capture, on any unrooted phone:
#   - app private data (/data/data/<pkg>): logins, sessions,
#     in-app settings, message history, game saves
#   - anything hardware-bound: bank device pairings, infakt's
#     phone pairing, mObywatel activation, Signal registration
#   - the Firefox profile (tabs, cookies, extension settings)
#
# Reading another app's private storage needs root or a
# debuggable build. `adb backup` is deprecated and a no-op for
# most apps since Android 12. That is a platform limit, not a
# gap in this script -- so it prints, at the end, an explicit
# list of what you will have to redo by hand.
#
# Usage:
#   ./phone_backup.sh [--out DIR] [--no-apks] [--verify DIR]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/adb_common.sh
source "${SCRIPT_DIR}/lib/adb_common.sh"
# shellcheck source=lib/backup_capture.sh
source "${SCRIPT_DIR}/lib/backup_capture.sh"
# shellcheck source=lib/backup_report.sh
source "${SCRIPT_DIR}/lib/backup_report.sh"

OUT_ROOT="${HOME}/data/phone-backup"
PULL_APKS=1
VERIFY_DIR=""

usage() {
	sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out)
		OUT_ROOT="${2:?--out needs a directory}"
		shift 2
		;;
	--no-apks)
		PULL_APKS=0
		shift
		;;
	--verify)
		VERIFY_DIR="${2:?--verify needs a directory}"
		shift 2
		;;
	-h | --help) usage ;;
	*)
		_error "Unknown flag: $1"
		exit 1
		;;
	esac
done

main() {
	if [[ -n "${VERIFY_DIR}" ]]; then
		verify_backup "${VERIFY_DIR}"
		return
	fi

	# shellcheck disable=SC2119  # intentional: no argument means "use $ADB_SERIAL, else the only device".
	# Forwarding "$@" here would pass this script's own flags as a serial.
	adb_select_device
	adb_verify_trusted_identity

	local stamp="" dir=""
	stamp="$(date +%Y-%m-%d-%H%M%S)"
	dir="${OUT_ROOT}/${DEVICE_SERIAL}-${stamp}"
	mkdir -p "${dir}"

	_box "PHONE BACKUP" \
		"Device: ${DEVICE_MODEL} (${DEVICE_SERIAL})" \
		"Output: ${dir}" \
		"This does NOT capture app private data -- see RESTORE-BY-HAND.md"

	dump_packages "${dir}"
	[[ "${PULL_APKS}" -eq 1 ]] && pull_apks "${dir}"
	pull_sdcard "${dir}"
	dump_settings "${dir}"
	dump_focus_state "${dir}"
	print_manual_checklist "${dir}"
	write_manifest "${dir}"

	verify_backup "${dir}"

	_info "Backup complete: ${dir}"
	_info "Total size: $(du -sh "${dir}" | cut -f1)"
}

main "$@"
