#!/usr/bin/env bash
# Unit tests for the three libraries split out of focus_daemon.sh, against the
# fake device in daemon_libs_harness.sh. No real phone is needed.
#
# This is the only entry point; the cases live in sourced files purely to stay
# under the 250-line cap, so one coverage command measures all three subjects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=daemon_libs_harness.sh
. "${SCRIPT_DIR}/daemon_libs_harness.sh"
# shellcheck source=daemon_cases_location.sh
. "${SCRIPT_DIR}/daemon_cases_location.sh"
# shellcheck source=daemon_cases_state.sh
. "${SCRIPT_DIR}/daemon_cases_state.sh"
# shellcheck source=daemon_cases_apps.sh
. "${SCRIPT_DIR}/daemon_cases_apps.sh"
# shellcheck source=daemon_cases_sweep.sh
. "${SCRIPT_DIR}/daemon_cases_sweep.sh"

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
