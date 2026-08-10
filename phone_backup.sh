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

OUT_ROOT="${HOME}/phone-backup"
PULL_APKS=1
VERIFY_DIR=""

# Directories pulled wholesale from shared storage. Anything not
# listed here is not backed up, so keep the list honest.
readonly SDCARD_DIRS=(
	DCIM
	Pictures
	Download
	Documents
	Movies
	Music
	Signal
	RunnerUp
)

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

# A backup nobody checked is not a backup. --verify re-reads the
# artefacts and fails loudly on anything empty or missing.
verify_backup() {
	local dir="${1:?}" failed=0 f=""
	_info "Verifying ${dir}"

	for f in packages-all.txt packages-third-party.txt settings-secure.txt manifest.txt; do
		if [[ ! -s "${dir}/${f}" ]]; then
			_error "missing or empty: ${f}"
			failed=1
		fi
	done

	if [[ -d "${dir}/apks" ]]; then
		local apk_count=0 broken=0 pkg_dirs=0 expected=0
		while IFS= read -r -d '' apk; do
			apk_count=$((apk_count + 1))
			# An APK is a zip; a truncated pull is the failure mode.
			unzip -t "${apk}" >/dev/null 2>&1 || {
				_error "corrupt APK: $(basename "${apk}")"
				broken=1
			}
		done < <(find "${dir}/apks" -name '*.apk' -print0 2>/dev/null)

		# Coverage, not just integrity: the stdin bug produced ONE
		# perfectly valid APK out of 54, which an integrity-only check
		# would have called a pass.
		pkg_dirs="$(find "${dir}/apks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
		expected="$(wc -l <"${dir}/packages-third-party.txt")"
		_info "APKs: ${apk_count} files across ${pkg_dirs}/${expected} packages"
		if [[ "${pkg_dirs}" -lt "${expected}" ]]; then
			_error "only ${pkg_dirs} of ${expected} packages have APKs"
			failed=1
		fi
		[[ "${broken}" -eq 1 ]] && failed=1
	fi

	local kdbx_count=0
	kdbx_count="$(find "${dir}/sdcard" -iname '*.kdbx' 2>/dev/null | wc -l)"
	if [[ "${kdbx_count}" -eq 0 ]]; then
		# Expected on this phone: the database lives in KeePassDX's
		# private storage and the canonical copy is on the PC. Noted
		# rather than warned so a real regression stays visible.
		_info "No .kdbx in shared storage (canonical copy is on the PC)"
	else
		_info "KeePassDX databases: ${kdbx_count}"
	fi

	if [[ "${failed}" -eq 1 ]]; then
		_error "VERIFY FAILED"
		return 1
	fi
	_info "Verify OK"
}

dump_packages() {
	local dir="$1"
	adb_cmd shell pm list packages | sed 's/^package://' | tr -d '\r' |
		sort >"${dir}/packages-all.txt"
	adb_cmd shell pm list packages -3 | sed 's/^package://' | tr -d '\r' |
		sort >"${dir}/packages-third-party.txt"
	# Packages removed for user 0 read as uninstalled here; recorded
	# separately so a restore knows what was deliberately purged.
	adb_cmd shell pm list packages -u | sed 's/^package://' | tr -d '\r' |
		sort >"${dir}/packages-including-removed.txt"
	comm -13 "${dir}/packages-all.txt" "${dir}/packages-including-removed.txt" \
		>"${dir}/packages-removed-for-user0.txt"
	_info "Packages: $(wc -l <"${dir}/packages-third-party.txt") third-party, $(wc -l <"${dir}/packages-removed-for-user0.txt") removed for user 0"
}

pull_apks() {
	local dir="$1" pkg="" path="" n=0 base=""
	local -a pkgs=() paths=()
	mkdir -p "${dir}/apks"

	# Read the list into an array FIRST. Iterating the file with
	# `while read < file` breaks after one package, because `adb`
	# inside the loop inherits and drains that same stdin -- measured:
	# it pulled 1 of 54 before this was fixed.
	mapfile -t pkgs <"${dir}/packages-third-party.txt"

	for pkg in "${pkgs[@]}"; do
		[[ -n "${pkg}" ]] || continue
		# A split app reports several paths (base + split_config.*).
		# All of them are needed for a working offline reinstall, so
		# each package gets its own directory rather than one file.
		mapfile -t paths < <(
			adb_cmd shell pm path "${pkg}" 2>/dev/null |
				sed 's/^package://' | tr -d '\r'
		)
		[[ "${#paths[@]}" -gt 0 ]] || {
			_warn "no APK path for ${pkg}"
			continue
		}
		mkdir -p "${dir}/apks/${pkg}"
		for path in "${paths[@]}"; do
			[[ -n "${path}" ]] || continue
			base="$(basename "${path}")"
			adb_cmd pull "${path}" "${dir}/apks/${pkg}/${base}" >/dev/null 2>&1 ||
				_warn "could not pull ${base} for ${pkg}"
		done
		n=$((n + 1))
	done
	_info "APKs pulled: ${n} packages, $(find "${dir}/apks" -name '*.apk' | wc -l) files"
}

pull_sdcard() {
	local dir="$1" d=""
	mkdir -p "${dir}/sdcard"
	for d in "${SDCARD_DIRS[@]}"; do
		if adb_cmd shell "test -d /sdcard/${d}" 2>/dev/null; then
			_info "Pulling /sdcard/${d}"
			adb_cmd pull "/sdcard/${d}" "${dir}/sdcard/" >/dev/null 2>&1 ||
				_warn "partial or failed pull: ${d}"
		fi
	done
	# Same stdin caveat as pull_apks: collect first, pull second.
	local -a kdbx_paths=()
	mapfile -t kdbx_paths < <(
		adb_cmd shell 'find /sdcard -iname "*.kdbx" 2>/dev/null' | tr -d '\r'
	)
	local kdbx=""
	for kdbx in "${kdbx_paths[@]}"; do
		[[ -n "${kdbx}" ]] || continue
		_info "Pulling KeePass database: ${kdbx}"
		mkdir -p "${dir}/sdcard/keepass"
		adb_cmd pull "${kdbx}" "${dir}/sdcard/keepass/" >/dev/null 2>&1 || true
	done
}

dump_settings() {
	local dir="$1" ns=""
	for ns in system secure global; do
		adb_cmd shell settings list "${ns}" | tr -d '\r' | sort \
			>"${dir}/settings-${ns}.txt"
	done
	_info "Settings captured (system/secure/global)"
}

dump_focus_state() {
	local dir="$1"
	{
		printf '# Focus-mode state at backup time\n'
		printf '# Restore with: phone_focus_mode/distraction_purge.sh\n\n'
		printf '## Packages removed for user 0\n'
		cat "${dir}/packages-removed-for-user0.txt"
		printf '\n## RethinkDNS installed: '
		grep -qx 'com.celzero.bravedns' "${dir}/packages-all.txt" &&
			printf 'yes\n' || printf 'no\n'
		printf '## uBlock filters live in the Firefox profile and CANNOT be\n'
		printf '## backed up from adb; see docs/youtube-block-unrooted.md\n'
	} >"${dir}/focus-state.md"
}

write_manifest() {
	local dir="$1"
	{
		printf 'Backup of %s (%s)\n' "${DEVICE_SERIAL}" "${DEVICE_MODEL}"
		printf 'Fingerprint: %s\n' "${DEVICE_FINGERPRINT}"
		printf 'Taken: %s\n' "$(date -Is)"
		printf 'Android: %s (SDK %s)\n' \
			"$(adb_cmd shell getprop ro.build.version.release | tr -d '\r')" \
			"$(adb_cmd shell getprop ro.build.version.sdk | tr -d '\r')"
		printf '\nContents:\n'
		du -sh "${dir}"/* 2>/dev/null | sed 's/^/  /'
	} >"${dir}/manifest.txt"
}

print_manual_checklist() {
	local dir="$1"
	cat >"${dir}/RESTORE-BY-HAND.md" <<'EOF'
# What this backup does NOT restore

Everything below is app-private or hardware-bound, so it is unreachable
from adb on an unrooted phone. Budget real time for it after a wipe.

## Must be re-authenticated (device pairing / re-activation)

- **infakt** (`pl.infakt.infakt`) — the account itself is server-side, so
  login + password works on a new device. BUT its banking side is
  device-paired ("Usuń powiązanie z telefonem" in Ustawienia bankowości)
  and the app PIN is local. Expect to re-pair via SMS to the registered
  number. Confirm 2FA method BEFORE wiping: SMS is safe, an authenticator
  app means the seed must be in KeePassDX.
- **mBank** (`pl.mbank`) — re-pair the device, SMS code, new app PIN.
- **Revolut** — re-login, SMS/email, possibly selfie re-verification.
- **mObywatel** (`pl.nask.mobywatel`) — full re-activation via Profil
  Zaufany or a bank login. Do this LAST: activating on a new device
  deactivates the old one, with no rollback.
- **Signal** — needs its own backup + the 30-digit passphrase. The
  restore prompt appears at install time ONLY.

## Lost unless separately exported

- Firefox: tabs, cookies, logins, and the uBlock Origin filter list
- App settings and in-app data for every third-party app
- Game/app progress not synced to a server

## Restore order that avoids a lockout

1. Google account (needs backup codes if 2FA is on a device you wiped)
2. KeePassDX, from the `.kdbx` in `sdcard/keepass/`
3. Signal, at install time
4. Banks (mBank, Revolut, infakt)
5. mObywatel last
6. Re-apply focus mode: `distraction_purge.sh`, reinstall RethinkDNS and
   re-add its domain rules, re-add the uBlock filters
EOF
	_info "Wrote ${dir}/RESTORE-BY-HAND.md -- read it before relying on this backup"
}

main() {
	if [[ -n "${VERIFY_DIR}" ]]; then
		verify_backup "${VERIFY_DIR}"
		return
	fi

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
