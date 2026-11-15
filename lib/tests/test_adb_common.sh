#!/usr/bin/env bash
# Unit tests for adb_common.sh and adb_locking.sh (no real device needed).
# The enrolled-device tests live in test_adb_trusted.sh; both share the
# fixtures in adb_test_harness.sh.
set -euo pipefail

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=adb_test_harness.sh
source "${_HARNESS_DIR}/adb_test_harness.sh"

test_box_does_not_crash() {
	_box "Test title" "line 1" "line 2" >/dev/null 2>&1
}

test_check_cooldown_zero_allows() {
	LAST_RUN_DIR="${TEST_TMPDIR}/cooldown-zero"
	adb_check_cooldown 0 "test_marker"
}

test_check_cooldown_blocks_when_marker_fresh() {
	LAST_RUN_DIR="${TEST_TMPDIR}/cooldown-block"
	mkdir -p "${LAST_RUN_DIR}"
	date +%s >"${LAST_RUN_DIR}/fresh_marker"

	if adb_check_cooldown 9999 "fresh_marker"; then
		return 1
	fi

	return 0
}

test_mark_last_run_creates_marker() {
	LAST_RUN_DIR="${TEST_TMPDIR}/mark-last-run"
	adb_mark_last_run "run_test"
	[[ -f "${LAST_RUN_DIR}/run_test" ]]
}

test_acquire_lock_creates_lock_directory() {
	LOCK_DIR="${TEST_TMPDIR}/lock-dir-create"
	LOCK_FILE=""
	adb_acquire_lock >/dev/null 2>&1
	[[ -d "${LOCK_FILE}" && -f "${LOCK_FILE}/pid" ]]
	_adb_release_lock
}

test_acquire_lock_removes_stale_lock_directory() {
	LOCK_DIR="${TEST_TMPDIR}/lock-dir-stale"
	LOCK_FILE="${LOCK_DIR}/run_phone.lock"
	mkdir -p "${LOCK_FILE}"
	printf '999999\n' >"${LOCK_FILE}/pid"

	adb_acquire_lock >/dev/null 2>&1
	[[ -d "${LOCK_FILE}" && -f "${LOCK_FILE}/pid" ]]
	_adb_release_lock
}

test_sanitize_device_string_removes_dangerous_chars() {
	local sanitized
	sanitized="$(_sanitize_device_string $'abc DEF-._:/$`";\n')"

	[[ "${sanitized}" == 'abc DEF-._:/' ]]
}

test_save_trusted_device_sanitizes_and_quotes() {
	local trusted_contents

	# Literal payload on purpose - see the note on ADB_MOCK_FINGERPRINT.
	# shellcheck disable=SC2016
	export ADB_SERIAL='SERIAL123$() ;'
	adb_save_trusted_device

	[[ -f "${ADB_ENROLLED_DEVICE_FILE}" ]] || return 1
	trusted_contents="$(cat "${ADB_ENROLLED_DEVICE_FILE}")"

	# Asserting the sanitiser stripped these metacharacters, so the patterns
	# must stay literal rather than expand.
	# shellcheck disable=SC2016
	[[ "${trusted_contents}" != *'$('* ]]
	[[ "${trusted_contents}" != *';'* ]]
	[[ "${trusted_contents}" != *'`'* ]]

	local -a trusted_values=()
	mapfile -t trusted_values < <(
		bash -c '
            set -euo pipefail
            source "$1"
            printf "%s\n" "${TRUSTED_SERIAL:-}" "${TRUSTED_MODEL:-}" "${TRUSTED_FINGERPRINT:-}"
        ' bash "${ADB_ENROLLED_DEVICE_FILE}"
	)

	[[ "${trusted_values[0]:-}" == 'SERIAL123 ' ]]
	[[ "${trusted_values[1]:-}" == 'Pixel 7rm -rf /dangerline2' ]]
	[[ "${trusted_values[2]:-}" == 'google/pixel:14/UP1A.231005.007/evilcmd' ]]
}

test_verify_root_uses_root_shell() {
	export ADB_SERIAL='SERIAL123'
	adb_verify_root >/dev/null 2>&1
}

test_detect_root_sets_flag_on_rooted_phone() {
	export ADB_SERIAL='SERIAL123'
	unset ADB_HAS_ROOT
	adb_detect_root >/dev/null 2>&1
	[[ "${ADB_HAS_ROOT:-}" == "1" ]]
}

# The unrooted Pixel: `su` is absent. Detection must not be fatal -- an
# exit inside the subshell fails this test -- and must say which mode it chose.
test_detect_root_falls_back_to_unrooted_mode() {
	local log="${TEST_TMPDIR}/detect.log"
	(
		export ADB_SERIAL='SERIAL123'
		adb() { return 1; }
		! adb -s SERIAL123 shell su || exit 1
		adb_detect_root 2>"${log}"
		[[ "${ADB_HAS_ROOT:-}" == "0" ]]
	) && grep -q 'unrooted mode' "${log}"
}

test_select_device_rejects_multiple_devices_even_with_trusted_record() {
	unset ADB_SERIAL

	adb_list_serials() {
		printf 'SERIAL123\nSERIAL999\n'
	}

	cat >"${ADB_ENROLLED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Pixel 7rm -rf /dangerline2'
TRUSTED_FINGERPRINT='google/pixel:14/UP1A.231005.007/evilcmd'
EOF

	# Empty arg = no requested serial, which is what this case exercises.
	if (adb_select_device "" >/dev/null 2>&1); then
		return 1
	fi

	return 0
}

run_test "_box output without crash" test_box_does_not_crash
run_test "adb_check_cooldown 0 returns 0 (proceed)" test_check_cooldown_zero_allows
run_test "adb_check_cooldown blocks when marker is fresh" test_check_cooldown_blocks_when_marker_fresh
run_test "adb_mark_last_run creates marker file" test_mark_last_run_creates_marker
run_test "adb_acquire_lock creates atomic lock directory" test_acquire_lock_creates_lock_directory
run_test "adb_acquire_lock replaces stale lock directory" test_acquire_lock_removes_stale_lock_directory
run_test "_sanitize_device_string strips dangerous characters" test_sanitize_device_string_removes_dangerous_chars
run_test "adb_save_trusted_device sanitizes and safely quotes values" test_save_trusted_device_sanitizes_and_quotes
run_test "adb_verify_root succeeds when root shell returns ok" test_verify_root_uses_root_shell
run_test "adb_detect_root sets ADB_HAS_ROOT=1 when su answers" test_detect_root_sets_flag_on_rooted_phone
run_test "adb_detect_root falls back to unrooted mode without dying" test_detect_root_falls_back_to_unrooted_mode
run_test "adb_select_device rejects multiple devices even with trusted record" test_select_device_rejects_multiple_devices_even_with_trusted_record

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
