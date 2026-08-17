#!/usr/bin/env bash
# Unit tests for hosts_mount.sh and hosts_magisk.sh — the two halves split out
# of hosts_enforcer.sh — against the fake device in hosts_libs_harness.sh.
# No real phone is needed.
#
# This is the only entry point; the cases live in two sourced files purely to
# stay under the 250-line cap, so one coverage command measures both subjects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hosts_libs_harness.sh
. "${SCRIPT_DIR}/hosts_libs_harness.sh"
# shellcheck source=hosts_cases_mount.sh
. "${SCRIPT_DIR}/hosts_cases_mount.sh"
# shellcheck source=hosts_cases_assert.sh
. "${SCRIPT_DIR}/hosts_cases_assert.sh"
# shellcheck source=hosts_cases_magisk.sh
. "${SCRIPT_DIR}/hosts_cases_magisk.sh"
# shellcheck source=hosts_cases_cache.sh
. "${SCRIPT_DIR}/hosts_cases_cache.sh"

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
