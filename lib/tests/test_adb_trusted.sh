#!/usr/bin/env bash
# Unit tests for adb_trusted.sh: verifying a connected phone against the
# enrolled-device records, and forgetting one. Shares the fixtures in
# adb_test_harness.sh with test_adb_common.sh.
set -euo pipefail

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=adb_test_harness.sh
source "${_HARNESS_DIR}/adb_test_harness.sh"

test_verify_trusted_identity_accepts_exact_match() {
	export ADB_SERIAL='SERIAL123'
	adb_save_trusted_device
	adb_verify_trusted_identity >/dev/null 2>&1
}

test_verify_trusted_identity_rejects_model_mismatch() {
	export ADB_SERIAL='SERIAL123'
	adb_save_trusted_device

	cat >"${ADB_ENROLLED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Different Model'
TRUSTED_FINGERPRINT='google/pixel:14/UP1A.231005.007/evilcmd'
EOF

	if (adb_verify_trusted_identity >/dev/null 2>&1); then
		return 1
	fi

	return 0
}

test_verify_trusted_identity_rejects_fingerprint_mismatch() {
	export ADB_SERIAL='SERIAL123'
	adb_save_trusted_device

	cat >"${ADB_ENROLLED_DEVICE_FILE}" <<'EOF'
TRUSTED_SERIAL='SERIAL123'
TRUSTED_MODEL='Pixel 7rm -rf /dangerline2'
TRUSTED_FINGERPRINT='different/fingerprint'
EOF

	if (adb_verify_trusted_identity >/dev/null 2>&1); then
		return 1
	fi

	return 0
}

test_verify_trusted_identity_accepts_any_enrolled_device() {
	# Two phones enrolled from one PC: the second must not evict the first,
	# which is the whole reason the store is a directory.
	export ADB_SERIAL='SERIAL_ONE'
	adb_save_trusted_device
	export ADB_SERIAL='SERIAL_TWO'
	adb_save_trusted_device

	adb_verify_trusted_identity >/dev/null 2>&1 || return 1

	export ADB_SERIAL='SERIAL_ONE'
	adb_verify_trusted_identity >/dev/null 2>&1 || return 1

	return 0
}

test_verify_trusted_identity_rejects_unenrolled_device() {
	export ADB_SERIAL='SERIAL_ONE'
	adb_save_trusted_device

	# An unknown serial must still abort, or multi-device support would have
	# quietly turned the guard off.
	export ADB_SERIAL='SERIAL_STRANGER'
	if (adb_verify_trusted_identity >/dev/null 2>&1); then
		return 1
	fi

	return 0
}

test_forget_trusted_device_removes_only_that_record() {
	export ADB_SERIAL='SERIAL_ONE'
	adb_save_trusted_device
	export ADB_SERIAL='SERIAL_TWO'
	adb_save_trusted_device

	adb_forget_trusted_device 'SERIAL_ONE' >/dev/null 2>&1

	adb_list_trusted_serials | grep -qx 'SERIAL_TWO' || return 1
	if adb_list_trusted_serials | grep -qx 'SERIAL_ONE'; then
		return 1
	fi

	return 0
}

run_test "adb_verify_trusted_identity accepts exact saved identity" test_verify_trusted_identity_accepts_exact_match
run_test "adb_verify_trusted_identity rejects model mismatch" test_verify_trusted_identity_rejects_model_mismatch
run_test "adb_verify_trusted_identity rejects fingerprint mismatch" test_verify_trusted_identity_rejects_fingerprint_mismatch
run_test "adb_verify_trusted_identity accepts any enrolled device" test_verify_trusted_identity_accepts_any_enrolled_device
run_test "adb_verify_trusted_identity rejects unenrolled device" test_verify_trusted_identity_rejects_unenrolled_device
run_test "adb_forget_trusted_device removes only that record" test_forget_trusted_device_removes_only_that_record

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
