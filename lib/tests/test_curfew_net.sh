#!/usr/bin/env bash
# Unit tests for curfew_net.sh — the per-UID network allow-list of the night
# curfew — against the stubs in curfew_net_harness.sh. No device needed.
#
# What matters here is not that rules are added but that they are added in an
# order that means something: every ACCEPT must precede the 10000-19999
# REJECT, or the whitelist lets nothing through.
#
# This is the only entry point; the cases live in two sourced files purely to
# stay under the 250-line cap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=curfew_net_harness.sh
. "${SCRIPT_DIR}/curfew_net_harness.sh"
# shellcheck source=curfew_net_cases_chain.sh
. "${SCRIPT_DIR}/curfew_net_cases_chain.sh"
# shellcheck source=curfew_net_cases_lifecycle.sh
. "${SCRIPT_DIR}/curfew_net_cases_lifecycle.sh"

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
