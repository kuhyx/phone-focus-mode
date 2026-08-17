#!/usr/bin/env bash
# lib/backup_capture.sh — the capture half of phone_backup.sh: package lists,
# third-party APKs, shared-storage directories, settings dumps and the
# focus-mode state. Each function is handed the output directory to fill.
#
# Sourced by phone_backup.sh, which owns adb_common.sh (adb_cmd, adb_shell,
# _info, _warn). SDCARD_DIRS lives here rather than in the entry script
# because pull_sdcard is its only reader, and a file must not assign a global
# it never reads (SC2034) — shellcheck runs without -x, so each file stands
# alone.

# Directories pulled wholesale from shared storage. Anything not
# listed here is not backed up, so keep the list honest.
# Written on one line rather than one entry per line: kcov instruments a
# multi-line literal's continuation lines but bash only ever reports the
# statement at its first line, so a list spanning N lines is permanently
# stuck at 1/N covered however thoroughly it is tested.
readonly SDCARD_DIRS=(DCIM Pictures Download Documents Movies Music Signal RunnerUp)

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
		mapfile -t paths < <(adb_cmd shell pm path "${pkg}" 2>/dev/null | sed 's/^package://' | tr -d '\r')
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
	mapfile -t kdbx_paths < <(adb_cmd shell 'find /sdcard -iname "*.kdbx" 2>/dev/null' | tr -d '\r')
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
	local out="${dir}/focus-state.md" rethink="no" purged=""

	# Built as one printf rather than a `{ ... } >file` group of many: kcov
	# counts the group's closing brace as an instrumented line that bash never
	# reports, and a run of individual redirects instead draws SC2129. One
	# statement satisfies both, and the repo forbids suppressing either.
	grep -qx 'com.celzero.bravedns' "${dir}/packages-all.txt" && rethink="yes"
	purged="$(cat "${dir}/packages-removed-for-user0.txt")"

	printf '%s\n%s\n\n%s\n%s\n\n%s%s\n%s\n%s\n' \
		'# Focus-mode state at backup time' \
		'# Restore with: phone_focus_mode/distraction_purge.sh' \
		'## Packages removed for user 0' \
		"${purged}" \
		'## RethinkDNS installed: ' "${rethink}" \
		'## uBlock filters live in the Firefox profile and CANNOT be' \
		'## backed up from adb; see docs/youtube-block-unrooted.md' \
		>"${out}"
}
