#!/usr/bin/env bash
# Unit + end-to-end tests for lib/adb_auto_target.sh (no real device needed).
#
# phone-auto-sync.timer runs `run_phone.sh auto` every 30 min. With nothing
# enrolled connected -- or nothing at all -- that must be a logged no-op
# exiting 0, not a FATAL every half hour. An enrolled phone qualifies with or
# without root (the Pixel 6a is unrooted for good); a rooted one wins a tie.
set -euo pipefail

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=adb_test_harness.sh
source "${_HARNESS_DIR}/adb_test_harness.sh"

ROOTED='ROOTED_ONE'
PLAIN='PIXEL_PLAIN'

# Overrides the harness mock: ADB_MOCK_DEVICES is "serial<TAB>state" lines;
# ADB_MOCK_ROOTED lists the serials whose `su` answers.
ADB_MOCK_DEVICES=""
ADB_MOCK_ROOTED=""
adb() {
	if [[ "$#" -eq 1 && "$1" == "devices" ]]; then
		printf 'List of devices attached\n%b' "${ADB_MOCK_DEVICES}"
		return 0
	fi
	if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "su" ]]; then
		[[ " ${ADB_MOCK_ROOTED} " == *" $2 "* ]] && { printf 'ok\r\n'; return 0; }
		printf 'su: inaccessible or not found\n' >&2
		return 1
	fi
	return 1
}

_enroll() {
	mkdir -p "${TRUSTED_DEVICE_DIR}"
	printf 'TRUSTED_SERIAL=%q\n' "$1" >"${TRUSTED_DEVICE_DIR}/$1.sh"
}

_reset() {
	rm -rf "${TRUSTED_DEVICE_DIR}" "${TRUSTED_DEVICE_FILE}"
	ADB_MOCK_DEVICES=""
	ADB_MOCK_ROOTED=""
}

test_nothing_connected_finds_no_target() {
	_reset
	_enroll "${ROOTED}"
	! adb_find_auto_target >/dev/null
}

test_unrooted_enrolled_phone_is_a_target() {
	_reset
	_enroll "${PLAIN}"
	ADB_MOCK_DEVICES="${PLAIN}\tdevice\n"
	[[ "$(adb_find_auto_target)" == "${PLAIN}" ]]
}

test_unrooted_unenrolled_phone_is_not_a_target() {
	_reset
	ADB_MOCK_DEVICES="${PLAIN}\tdevice\n"
	! adb_find_auto_target >/dev/null
}

test_rooted_but_unenrolled_phone_is_not_a_target() {
	_reset
	ADB_MOCK_DEVICES="${ROOTED}\tdevice\n"
	ADB_MOCK_ROOTED="${ROOTED}"
	! adb_find_auto_target >/dev/null
}

test_picks_the_rooted_enrolled_phone_beside_the_pixel() {
	_reset
	_enroll "${PLAIN}"
	_enroll "${ROOTED}"
	ADB_MOCK_DEVICES="${PLAIN}\tdevice\n${ROOTED}\tdevice\n"
	ADB_MOCK_ROOTED="${ROOTED}"
	[[ "$(adb_find_auto_target)" == "${ROOTED}" ]]
}

test_unauthorized_phone_is_skipped() {
	_reset
	_enroll "${ROOTED}"
	ADB_MOCK_DEVICES="${ROOTED}\tunauthorized\n"
	ADB_MOCK_ROOTED="${ROOTED}"
	! adb_find_auto_target >/dev/null
}

test_legacy_single_record_counts_as_enrolled() {
	_reset
	mkdir -p "$(dirname "${TRUSTED_DEVICE_FILE}")"
	printf 'TRUSTED_SERIAL=%q\n' "${ROOTED}" >"${TRUSTED_DEVICE_FILE}"
	ADB_MOCK_DEVICES="${ROOTED}\tdevice\n"
	ADB_MOCK_ROOTED="${ROOTED}"
	[[ "$(adb_find_auto_target)" == "${ROOTED}" ]]
}

# End to end: the real run_phone.sh, a fake adb on PATH, only an UNENROLLED
# phone. Enrolled phones get the full run; see test_run_phone_unrooted.sh.
test_run_phone_auto_is_a_clean_noop_with_only_an_unenrolled_phone() {
	local bin="${TEST_TMPDIR}/bin" state="${TEST_TMPDIR}/e2e-state" out="" rc=0
	mkdir -p "${bin}" "${state}/phone_focus_mode/trusted_devices"
	printf 'TRUSTED_SERIAL=%q\n' "${ROOTED}" >"${state}/phone_focus_mode/trusted_devices/${ROOTED}.sh"
	cat >"${bin}/adb" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "devices" ]] && { printf 'List of devices attached\n${PLAIN}\tdevice\n'; exit 0; }
[[ "\$4" == "su" ]] && { echo 'su: inaccessible or not found' >&2; exit 1; }
echo "unexpected adb call: \$*" >&2; exit 3
EOF
	chmod +x "${bin}/adb"
	out="$(env -u ADB_SERIAL PATH="${bin}:${PATH}" XDG_STATE_HOME="${state}" \
		bash "${_HARNESS_DIR}/../../run_phone.sh" auto 2>&1)" || rc=$?
	[[ "${rc}" -eq 0 ]] || { printf '    rc=%s\n%s\n' "${rc}" "${out}"; return 1; }
	[[ "${out}" == *"no enrolled phone connected (${PLAIN} ); nothing to do."* ]] || {
		printf '%s\n' "${out}"
		return 1
	}
	[[ "${out}" != *"unexpected adb call"* ]]
}

run_test "nothing connected -> no target" test_nothing_connected_finds_no_target
run_test "enrolled unrooted phone (Pixel) -> target" test_unrooted_enrolled_phone_is_a_target
run_test "unenrolled unrooted phone -> no target" test_unrooted_unenrolled_phone_is_not_a_target
run_test "rooted but unenrolled -> no target" test_rooted_but_unenrolled_phone_is_not_a_target
run_test "rooted enrolled phone chosen beside the Pixel" test_picks_the_rooted_enrolled_phone_beside_the_pixel
run_test "unauthorized phone skipped" test_unauthorized_phone_is_skipped
run_test "legacy single record counts as enrolled" test_legacy_single_record_counts_as_enrolled
run_test "run_phone.sh auto is a clean no-op with only an unenrolled phone" test_run_phone_auto_is_a_clean_noop_with_only_an_unenrolled_phone

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
