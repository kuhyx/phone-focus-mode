#!/usr/bin/env bash
# lib/backup_unrooted.sh — run_phone.sh's backup for a phone WITHOUT root
# (the Pixel 6a). Writes the same history/<ts>/ + latest layout as the rooted
# backup, filled by the unrooted capture that phone_backup.sh also uses:
# package lists, every third-party APK, shared storage, settings, the Device
# Owner record, and the RESTORE-BY-HAND checklist. verify_backup must pass
# before latest/ moves, so a half-pulled snapshot never becomes "latest".
#
# Read-only: pm list/path, settings list, dpm list-owners, getprop, find,
# test -d and adb pull. No su, no pm/settings/dpm/am write.
#
# Sourced by backup.sh (which owns _backup_update_latest, backup_device_info
# and backup_prune_history). Needs adb_common.sh and backup_manifest.sh.

_BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup_capture.sh
source "${_BACKUP_LIB_DIR}/backup_capture.sh"
# shellcheck source=backup_report.sh
source "${_BACKUP_LIB_DIR}/backup_report.sh"

backup_device_owner() {
	adb_cmd shell dpm list-owners 2>/dev/null | tr -d '\r' >"$1/device_owner.txt" || true
}

# Daily snapshots of ~1.3 GB of shared storage would cost ~40 GB a month.
# Identical files across history/ become hardlinks, so an unchanged photo is
# stored once. A missing `hardlink` only costs disk space, so it warns.
_backup_dedup_history() {
	local history_dir="$1/history"

	if command -v hardlink >/dev/null 2>&1; then
		hardlink -q -c "${history_dir}" >/dev/null 2>&1 || _warn "hardlink dedup failed in ${history_dir}"
	else
		_warn "hardlink (util-linux) not found; history is not deduplicated"
	fi
}

backup_run_unrooted() {
	local device_id="$1"
	local device_root="${PHONE_BACKUP_ROOT}/${device_id}"
	local final_dir="" snapshot_dir=""

	# Pulled into <ts>.partial and renamed only once verify_backup passes, so
	# a run that dies mid-pull (the phone dropping off adb, a full disk) can
	# never pass for a snapshot. A .partial left by an earlier failure holds
	# nothing the phone does not, so it is dropped first.
	final_dir="${device_root}/history/$(date -u +%Y%m%dT%H%M%SZ)"
	snapshot_dir="${final_dir}.partial"
	find "${device_root}/history" -mindepth 1 -maxdepth 1 -type d -name '*.partial' \
		-exec rm -rf '{}' + 2>/dev/null || true
	mkdir -p "${snapshot_dir}/device_info"
	_info "Starting unrooted backup to ${snapshot_dir}"

	backup_device_info "${snapshot_dir}"
	dump_packages "${snapshot_dir}"
	pull_apks "${snapshot_dir}"
	pull_sdcard "${snapshot_dir}"
	dump_settings "${snapshot_dir}"
	backup_device_owner "${snapshot_dir}"
	dump_focus_state "${snapshot_dir}"
	print_manual_checklist "${snapshot_dir}"
	write_manifest "${snapshot_dir}"

	verify_backup "${snapshot_dir}" || _fatal "Backup failed verification; latest/ left unchanged: ${snapshot_dir}"
	mv "${snapshot_dir}" "${final_dir}"
	snapshot_dir="${final_dir}"

	_backup_update_latest "${snapshot_dir}" "${device_root}"
	_backup_dedup_history "${device_root}"
	backup_prune_history "${device_root}"
	_info "Backup complete: ${snapshot_dir} ($(du -sh "${snapshot_dir}" | cut -f1))"
	printf '%s\n' "${snapshot_dir}"
}
