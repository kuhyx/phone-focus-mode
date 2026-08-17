#!/usr/bin/env bash
# lib/tests/adb_test_harness.sh — shared fixtures for the adb_common test files.
# Sourced by test_adb_common.sh and test_adb_trusted.sh; not a test file itself.
#
# Provides: the PASS/FAIL counters, run_test, a TEST_TMPDIR with an EXIT trap,
# an XDG_STATE_HOME redirect so no test touches the real state dir, the adb()
# mock, and the two injection payloads the sanitiser is tested against.
# Unit tests for adb_common.sh helper functions (no real device needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

_t_pass() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

export XDG_STATE_HOME="${TEST_TMPDIR}/state"
mkdir -p "${XDG_STATE_HOME}"

source "${SCRIPT_DIR}/../adb_common.sh"

ADB_MOCK_MODEL=$'Pixel "7";$(rm -rf /)`danger`\nline2'
# Single quotes are the whole point: this is an injection payload that must
# reach the code under test LITERALLY. Expanding $evil / `cmd` here would
# execute them in the test harness and test nothing.
# shellcheck disable=SC2016
ADB_MOCK_FINGERPRINT='google/pixel:14/UP1A.231005.007/$evil;`cmd`'

adb() {
	if [[ "$#" -eq 1 && "$1" == "devices" ]]; then
		printf 'List of devices attached\nSERIAL123\tdevice\n'
		return 0
	fi

	if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "getprop" && "$5" == "ro.product.model" ]]; then
		printf '%s\r\n' "${ADB_MOCK_MODEL}"
		return 0
	fi

	if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "getprop" && "$5" == "ro.build.fingerprint" ]]; then
		printf '%s\r\n' "${ADB_MOCK_FINGERPRINT}"
		return 0
	fi

	if [[ "$1" == "-s" && "$3" == "shell" && "$4" == "su" && "$5" == "--mount-master" && "$6" == "-c" && "$7" == "echo ok" ]]; then
		printf 'ok\n'
		return 0
	fi

	printf 'Unexpected adb invocation:' >&2
	printf ' %q' "$@" >&2
	printf '\n' >&2
	return 1
}

run_test() {
	local name="$1"
	shift

	if "$@"; then
		_t_pass "${name}"
	else
		_t_fail "${name}"
	fi
}
