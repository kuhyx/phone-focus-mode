#!/usr/bin/env bash
# Unit tests for monitor.sh and its two probe libraries, against the fake
# device in monitor_harness.sh. No real device is needed.
#
# Every _check_* status branch gets its own case: the probes are what decides
# whether enforcement is reported as healthy, so a probe that silently always
# says "ok" is the failure this file exists to catch.
#
# This is the only entry point — the cases live in two sourced files purely to
# stay under the 250-line cap, so one run still measures all three subjects:
#
#   bash meta/scripts/shell_coverage.sh \
#       phone_focus_mode/lib/tests/test_monitor.sh monitor.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=monitor_harness.sh
. "${SCRIPT_DIR}/monitor_harness.sh"
# shellcheck source=monitor_cases_health.sh
. "${SCRIPT_DIR}/monitor_cases_health.sh"
# shellcheck source=monitor_cases_policy.sh
. "${SCRIPT_DIR}/monitor_cases_policy.sh"

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
