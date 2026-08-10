#!/usr/bin/env bash
# ============================================================
# Distraction purge — remove YouTube et al. for the primary user
#
# `pm uninstall --user 0` unregisters a package for one user while
# leaving the APK on the read-only system image. It needs no root, no
# Device Owner and no factory reset, and — unlike `pm suspend` and
# `pm disable-user`, both measured to be cleared by a reboot on this
# device — it SURVIVES A REBOOT. Verified on the Pixel 6a on
# 2026-08-09: uninstalled, rebooted, still `installed=false`.
#
# It is fully reversible: `pm install-existing --user 0 <pkg>` brings
# the app back with no download, which `--restore` does.
#
# This exists because focus_owner cannot do the job. Its sweep filters
# to third-party packages, and YouTube ships at /product/app/YouTube
# with FLAG_SYSTEM — so the Device Owner path would skip it even after
# the wipe. See docs/youtube-block-unrooted.md.
#
# Usage:
#   ./distraction_purge.sh            # purge (default)
#   ./distraction_purge.sh --list     # dry run, change nothing
#   ./distraction_purge.sh --status   # report current state
#   ./distraction_purge.sh --restore  # put every package back
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/adb_common.sh
source "${SCRIPT_DIR}/lib/adb_common.sh"

# Packages removed for user 0. Keep this list narrow and deliberate:
# every entry is an app the user has decided they do not want reachable,
# not general debloating (batch3_bloatware_uninstall.sh does that).
readonly PURGE_PACKAGES=(
	com.google.android.youtube
	com.google.android.apps.youtube.music
	# Chrome closes the web route to youtube.com, which removing the app
	# alone leaves wide open. It is the only browser on this device, so
	# this also removes in-app links, OAuth flows and anything else that
	# wants a browser -- accepted deliberately, and the reason --restore
	# exists and is a single command.
	com.android.chrome
)

MODE="purge"

usage() {
	sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
}

for arg in "$@"; do
	case "${arg}" in
	--list) MODE="list" ;;
	--status) MODE="status" ;;
	--restore) MODE="restore" ;;
	-h | --help) usage ;;
	*)
		_error "Unknown flag: ${arg}"
		exit 1
		;;
	esac
done

# Reports "installed", "absent", or "missing" (not on the image at all).
package_state() {
	local pkg="$1" line
	line="$(adb_cmd shell "dumpsys package ${pkg} 2>/dev/null \
        | sed -n '/User 0:/,/^ *User /p' \
        | grep -oE 'installed=[a-z]+' | head -1" | tr -d '\r')"
	case "${line}" in
	installed=true) printf 'installed' ;;
	installed=false) printf 'absent' ;;
	*) printf 'missing' ;;
	esac
}

report_state() {
	local pkg state
	for pkg in "${PURGE_PACKAGES[@]}"; do
		state="$(package_state "${pkg}")"
		printf '  %-44s %s\n' "${pkg}" "${state}"
	done
}

# Exits non-zero if any package is still reachable, so the caller (or a
# timer) learns about a Play Store reinstall instead of assuming success.
purge_packages() {
	local pkg state failed=0
	for pkg in "${PURGE_PACKAGES[@]}"; do
		state="$(package_state "${pkg}")"
		if [[ "${state}" == "missing" ]]; then
			_warn "${pkg}: not present on this device, skipping"
			continue
		fi
		if [[ "${state}" == "absent" ]]; then
			_info "${pkg}: already absent"
			continue
		fi
		if adb_cmd shell pm uninstall --user 0 "${pkg}" >/dev/null 2>&1; then
			_info "${pkg}: removed for user 0"
		else
			_error "${pkg}: uninstall failed"
		fi
		# Trust the device, not the exit code: `pm uninstall` has been
		# observed printing Success while leaving the package in place.
		if [[ "$(package_state "${pkg}")" == "installed" ]]; then
			_error "${pkg}: STILL INSTALLED after uninstall"
			failed=1
		fi
	done
	return "${failed}"
}

restore_packages() {
	local pkg
	for pkg in "${PURGE_PACKAGES[@]}"; do
		if adb_cmd shell pm install-existing --user 0 "${pkg}" >/dev/null 2>&1; then
			_info "${pkg}: restored"
		else
			_error "${pkg}: restore failed"
		fi
	done
}

main() {
	adb_select_device
	adb_verify_trusted_identity

	case "${MODE}" in
	list)
		_info "Would remove for user 0 (nothing changed):"
		printf '  %s\n' "${PURGE_PACKAGES[@]}"
		;;
	status)
		_info "Current state:"
		report_state
		;;
	restore)
		_box "RESTORING DISTRACTION APPS" \
			"Every package below becomes reachable again."
		restore_packages
		_info "Final state:"
		report_state
		;;
	purge)
		purge_packages || {
			_error "One or more packages are still installed."
			_info "Final state:"
			report_state
			exit 1
		}
		_info "Final state:"
		report_state
		;;
	esac
}

main "$@"
