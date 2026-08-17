#!/usr/bin/env bash
# Unit tests for the libraries split out of focus_ctl.sh, against the fake
# device in ctl_libs_harness.sh. No real phone is needed.
#
# This is the only entry point; the cases live in sourced files purely to stay
# under the 250-line cap, so one coverage command measures every subject.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR

# shellcheck source=ctl_libs_harness.sh
. "${TESTS_DIR}/ctl_libs_harness.sh"
# shellcheck source=ctl_cases_curfew.sh
. "${TESTS_DIR}/ctl_cases_curfew.sh"
# shellcheck source=ctl_cases_commands.sh
. "${TESTS_DIR}/ctl_cases_commands.sh"
# shellcheck source=ctl_cases_daemon.sh
. "${TESTS_DIR}/ctl_cases_daemon.sh"

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
