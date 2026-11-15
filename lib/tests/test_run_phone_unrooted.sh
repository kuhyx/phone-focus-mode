#!/usr/bin/env bash
# End-to-end tests for run_phone.sh against an UNROOTED phone (the Pixel 6a:
# stock, locked, Device Owner = com.kuhy.focus_owner, no `su`).
#
# A fake `adb` on PATH runs each `adb shell` command in a local bash whose
# PATH holds stub pm/dpm/settings/dumpsys/df/getprop/su binaries, and maps
# /sdcard onto a temp dir, so pull_sdcard, find and test -d behave for real.
# Every adb call is logged: the read-only rule is asserted against that log.
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUN_PHONE="${_DIR}/../../run_phone.sh"
readonly SERIAL='PIXEL6A'
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP}"' EXIT
readonly BIN="${TMP}/bin" STUBS="${TMP}/stubs" PHONE="${TMP}/phone" ADB_LOG="${TMP}/adb.log"
export ADB_LOG STUBS PHONE

_t() {
	if "$@"; then
		PASS=$((PASS + 1))
		printf '  OK: %s\n' "${T_NAME}"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "${T_NAME}"
	fi
}

# _stub <name> <<'EOF' ... EOF — a fake phone binary, body on stdin.
_stub() {
	{
		printf '#!/usr/bin/env bash\n'
		cat
	} >"${STUBS}/$1"
	chmod +x "${STUBS}/$1"
}

_build_phone() {
	mkdir -p "${BIN}" "${STUBS}" "${PHONE}/sdcard/DCIM/Camera" "${PHONE}/sdcard/Download"
	printf 'jpeg' >"${PHONE}/sdcard/DCIM/Camera/a.jpg"
	printf 'jpeg-b' >"${PHONE}/sdcard/DCIM/Camera/b.jpg"
	printf 'pdf' >"${PHONE}/sdcard/Download/c.pdf"
	local pkg=""
	for pkg in com.kuhy.focus_owner com.celzero.bravedns; do
		mkdir -p "${PHONE}/data/app/${pkg}"
		printf 'x' >"${TMP}/AndroidManifest.xml"
		(cd "${TMP}" && zip -q "${PHONE}/data/app/${pkg}/base.apk" AndroidManifest.xml)
	done

	cat >"${BIN}/adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ADB_LOG}"
if [[ "$1" == "devices" ]]; then
	printf 'List of devices attached\nPIXEL6A\tdevice\n'
	exit 0
fi
shift 2
sub="$1"
shift
case "${sub}" in
shell) cmd="$*"; exec env PATH="${STUBS}:${PATH}" bash -c "${cmd//\/sdcard/${PHONE}/sdcard}" ;;
pull) src="${1//\/sdcard/${PHONE}/sdcard}"; cp -r "${src}" "$2" ;;
*) echo "fake adb: unsupported ${sub}" >&2; exit 3 ;;
esac
EOF
	chmod +x "${BIN}/adb"

	_stub su <<'STUB'
echo "su: inaccessible or not found" >&2
exit 127
STUB
	_stub getprop <<'STUB'
case "$1" in
ro.product.model) echo "Pixel 6a" ;;
ro.build.fingerprint) echo "google/bluejay/bluejay:17/X/1:user/release-keys" ;;
*) echo 17 ;;
esac
STUB
	_stub dumpsys <<'STUB'
printf '  level: 41\n  health: 2\n  temperature: 244\n'
STUB
	_stub df <<'STUB'
printf 'Filesystem 1K-blocks Used Available\n/dev/fuse 115621972 92314896 23176004\n'
STUB
	_stub dpm <<'STUB'
[[ -f "${PHONE}/wiped" ]] && { echo "No owners"; exit 0; }
echo "User 0: admin=com.kuhy.focus_owner/.FocusDeviceAdminReceiver,DeviceOwner"
STUB
	_stub settings <<'STUB'
[[ "$1" == list ]] && { echo "k=v"; exit 0; }
echo opportunistic
STUB
	# pm list packages [-3|-u|-e] [filter] / pm path <pkg>
	_stub pm <<'STUB'
if [[ "$1" == path ]]; then
	f="${PHONE}/data/app/$2/base.apk"
	[[ -f "$f" ]] && echo "package:$f"
	exit 0
fi
shift 2
flag=""
[[ "${1:-}" == -* ]] && { flag="$1"; shift; }
filter="${1:-}"
pkgs="com.android.systemui"
[[ "${flag}" == -3 ]] && pkgs=""
# An app whose APK cannot be resolved: the backup must fail verification.
[[ -f "${PHONE}/broken" ]] && pkgs="${pkgs} com.broken.app"
[[ -f "${PHONE}/wiped" ]] || pkgs="${pkgs} com.kuhy.focus_owner com.celzero.bravedns"
for p in ${pkgs}; do
	[[ -z "${filter}" || "${p}" == *"${filter}"* ]] && echo "package:${p}"
done
exit 0
STUB
}

_run() {
	local out="" rc=0
	out="$(env -u ADB_SERIAL PATH="${BIN}:${PATH}" XDG_STATE_HOME="${TMP}/state" \
		PHONE_BACKUP_ROOT="${TMP}/backups" bash "${RUN_PHONE}" "$@" 2>&1)" || rc=$?
	printf '%s\n__rc=%s\n' "${out}" "${rc}"
}

_has() { [[ "${OUT}" == *"$1"* ]] || { printf '    missing %q in:\n%s\n' "$1" "${OUT}"; return 1; }; }

_build_phone

_help_ok() {
	_has "enroll" && _has "without root" && _has "__rc=0" && [[ "${OUT}" != *"attempt is marked"* ]]
}

_enroll_ok() {
	_has "Enrolled device: model='Pixel 6a' serial='${SERIAL}'" && _has "__rc=0" &&
		[[ -f "${TMP}/state/phone_focus_mode/trusted_devices/${SERIAL}.sh" ]]
}

_monitor_ok() {
	_has "unrooted mode" && _has "Skipped (needs root)" && _has "__rc=0" && [[ "${OUT}" != *FATAL* ]]
}

_report_clean() {
	local report=""
	report="$(find "${TMP}/backups/${SERIAL}/monitoring" -name report.json 2>/dev/null | head -1 || true)"
	[[ -n "${report}" ]] &&
		jq -e '[.checks[] | select(.status == "error" or .status == "fatal")] | length == 0' "${report}" >/dev/null
}

_backup_ok() {
	local f=""
	_has "Verify OK" && _has "__rc=0" || return 1
	for f in packages-all.txt settings-secure.txt manifest.txt device_owner.txt; do
		[[ -s "${L}/${f}" ]] || { echo "    missing ${f}"; return 1; }
	done
	[[ -f "${L}/apks/com.kuhy.focus_owner/base.apk" ]] &&
		[[ "$(find "${L}/sdcard/DCIM" -type f | wc -l)" -eq 2 ]]
}

_auto_ok() {
	_has "unrooted mode" && _has "backup throttled" && _has "Monitoring Summary" &&
		_has "__rc=0" && [[ "${OUT}" != *WIPED* ]]
}

_cooldown_ok() { _has "cooldown active, nothing to do" && _has "__rc=0"; }

_dedup_ok() {
	_has "__rc=0" &&
		[[ "$(find "${TMP}/backups/${SERIAL}/history" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]] &&
		[[ "$(stat -c %h "${L}/sdcard/DCIM/Camera/a.jpg")" -eq 2 ]]
}

# The read-only rule: the only su call is detection's `echo ok` probe.
_read_only_ok() {
	local allowed='^(devices|-s PIXEL6A (pull .*|shell (su --mount-master -c echo ok|getprop.*|pm list packages.*|pm path [a-z._]+|test -d /sdcard/[A-Za-z]+|find /sdcard .*|settings (list|get) .*|dpm list-owners.*|dumpsys battery.*|df( .*)?)))$'
	! grep -vE "${allowed}" "${ADB_LOG}" | sort -u | sed 's/^/    not allowlisted: /' | grep .
}

_backup_tree() { find "${TMP}/backups" -mindepth 3 -maxdepth 3 2>/dev/null | sort || true; }

_wipe_ok() {
	_has "PHONE APPEARS TO HAVE BEEN WIPED" && _has "unrooted, so no fresh-phone" && _has "__rc=2" && [[ "$(_backup_tree)" == "${BEFORE}" ]]
}

T_NAME="--help lists enroll and says what works without root"
OUT="$(_run --help)"
_t _help_ok

T_NAME="enroll records the phone without root"
OUT="$(_run enroll)"
_t _enroll_ok

T_NAME="monitor runs in unrooted mode and exits 0"
OUT="$(_run monitor)"
_t _monitor_ok

T_NAME="monitor report has no error check"
_t _report_clean

T_NAME="backup writes a verified unrooted snapshot under latest/"
OUT="$(_run backup)"
L="${TMP}/backups/${SERIAL}/latest"
_t _backup_ok

T_NAME="auto runs the enrolled unrooted phone, backup throttled after the manual one"
# The manual `backup` above set the backup marker; clear only auto's cooldown.
rm -f "${TMP}/state/phone_focus_mode/last_run/auto"
OUT="$(_run auto)"
_t _auto_ok

T_NAME="a second auto at once is a cooldown no-op"
OUT="$(_run auto)"
_t _cooldown_ok

T_NAME="a second backup stores unchanged files once (hardlinked history)"
sleep 1
OUT="$(_run backup)"
_t _dedup_ok

_failed_backup_ok() {
	_has "__rc=1" && [[ "$(readlink "${L}")" == "${LATEST_BEFORE}" ]] &&
		[[ "$(find "${TMP}/backups/${SERIAL}/history" -mindepth 1 -maxdepth 1 ! -name '*.partial' | wc -l)" -eq 2 ]]
}

T_NAME="a backup that fails verification leaves latest/ and history/ alone"
touch "${PHONE}/broken"
LATEST_BEFORE="$(readlink "${L}")"
sleep 1
OUT="$(_run backup)"
rm -f "${PHONE}/broken"
_t _failed_backup_ok

T_NAME="every adb call was read-only"
_t _read_only_ok

T_NAME="a wiped phone makes auto warn, exit 2, and write nothing"
touch "${PHONE}/wiped"
rm -rf "${TMP}/state/phone_focus_mode/last_run"
BEFORE="$(_backup_tree)"
OUT="$(_run auto)"
_t _wipe_ok

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
