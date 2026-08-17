#!/usr/bin/env bash
# lib/tests/monitor_cases_policy.sh — enforcement-integrity assertions:
# hosts integrity, DNS, launcher state, companion app, boot persistence, and
# the snapshot/summary/severity surface of monitor.sh.
#
# Sourced by test_monitor.sh after monitor_harness.sh, which owns the fake
# device, the subject, and the PASS/FAIL counters this file adds to. Split out
# to keep every test file under the repo's 250-line cap; one entry point still
# runs the lot, so a single coverage command measures all three subjects.
set -euo pipefail

# --- hosts integrity --------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_hosts_integrity)" status)" \
    "hosts integrity skipped when no hosts target exists"

_dev_present /system/etc/hosts
_t_eq "fatal" "$(_field "$(_probe _check_hosts_integrity)" status)" \
    "hosts integrity fatal when the canonical copy is missing"

_dev_present /data/local/tmp/focus_mode/hosts.canonical
_t_eq "error" "$(_field "$(_probe _check_hosts_integrity)" status)" \
    "hosts integrity errors when the hashes cannot be read"

_dev_set hosts_expected_sha "abc123def456789"
_t_eq "error" "$(_field "$(_probe _check_hosts_integrity)" status)" \
    "hosts integrity errors when only one hash is readable"

_dev_set hosts_actual_sha "999888777666555"
json="$(_probe _check_hosts_integrity)"
_t_eq "error" "$(_field "${json}" status)" "hosts integrity errors on a hash mismatch"
case "$(_field "${json}" message)" in
    *"Hosts mismatch"*) _t_pass "hosts integrity names the mismatch" ;;
    *) _t_fail "hosts integrity message should report a mismatch" ;;
esac

_dev_set hosts_actual_sha "abc123def456789"
_t_eq "ok" "$(_field "$(_probe _check_hosts_integrity)" status)" \
    "hosts integrity ok when the hashes agree"

# --- DNS --------------------------------------------------------------------

_dev_reset
_t_eq "error" "$(_field "$(_probe _check_dns)" status)" \
    "dns errors when private DNS is off but the chains are missing"

_dev_present dns_chain
_t_eq "ok" "$(_field "$(_probe _check_dns)" status)" \
    "dns ok when private DNS is off and the chains exist"

_dev_set private_dns_mode "off"
_t_eq "ok" "$(_field "$(_probe _check_dns)" status)" "dns ok for an explicit off mode"

_dev_set private_dns_mode "null"
_t_eq "ok" "$(_field "$(_probe _check_dns)" status)" "dns ok for a null mode"

_dev_set private_dns_mode "hostname"
json="$(_probe _check_dns)"
_t_eq "error" "$(_field "${json}" status)" "dns errors when private DNS is enabled"
case "$(_field "${json}" message)" in
    *"mode=hostname"*) _t_pass "dns names the enabled mode" ;;
    *) _t_fail "dns should report the enabled mode" ;;
esac

# --- launcher state ---------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_launcher)" status)" \
    "launcher warns when it is absent and unconfigured"

_dev_present /data/local/tmp/focus_mode/minimalist_launcher.activity
_t_eq "fatal" "$(_field "$(_probe _check_launcher)" status)" \
    "launcher fatal when a snapshot exists but the package is gone"

_dev_reset
_dev_present pkg_launcher
_t_eq "warn" "$(_field "$(_probe _check_launcher)" status)" \
    "launcher warns when the snapshot metadata is empty"

_dev_set launcher_desired "com.qqlabs.minimalistlauncher/.MainActivity"
_dev_set launcher_actual "com.android.launcher3/.Launcher"
json="$(_probe _check_launcher)"
_t_eq "error" "$(_field "${json}" status)" "launcher errors on a HOME activity mismatch"
case "$(_field "${json}" message)" in
    *"Launcher default mismatch"*) _t_pass "launcher names the mismatch" ;;
    *) _t_fail "launcher should report the default mismatch" ;;
esac

_dev_set launcher_actual "com.qqlabs.minimalistlauncher/.MainActivity"
_t_eq "ok" "$(_field "$(_probe _check_launcher)" status)" "launcher ok when the activities agree"

# An unreadable current activity must not be reported as a mismatch.
_dev_reset
_dev_present pkg_launcher
_dev_set launcher_desired "com.qqlabs.minimalistlauncher/.MainActivity"
_t_eq "ok" "$(_field "$(_probe _check_launcher)" status)" \
    "launcher ok when the active activity cannot be read"

# --- companion app and boot persistence -------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_companion_app)" status)" "companion app warns when missing"

_dev_present pkg_companion
_t_eq "ok" "$(_field "$(_probe _check_companion_app)" status)" "companion app ok when installed"

_dev_reset
_t_eq "fatal" "$(_field "$(_probe _check_boot_persistence)" status)" \
    "boot persistence fatal when the Magisk script is missing"

_dev_present /data/adb/service.d/99-focus-mode.sh
json="$(_probe _check_boot_persistence)"
_t_eq "ok" "$(_field "${json}" status)" \
    "boot persistence ok when the Magisk script is executable"
case "${json}" in
    *'"repairable":false'*) _t_pass "a healthy check is not marked repairable" ;;
    *) _t_fail "a healthy check must not be repairable: ${json}" ;;
esac

# --- snapshot, summary and severity ----------------------------------------

_dev_reset
SNAP="${TEST_TMPDIR}/snap/run"
monitor_collect_snapshot "${SNAP}"

if [[ -f "${SNAP}/report.json" ]]; then
    _t_pass "collect_snapshot writes report.json"
else
    _t_fail "collect_snapshot did not write report.json"
fi

if [[ -f "${TEST_TMPDIR}/snap/latest.json" ]]; then
    _t_pass "collect_snapshot copies the report to latest.json"
else
    _t_fail "collect_snapshot did not write latest.json"
fi

checks_seen="$(grep -o '"check":"[a-z_]*"' "${SNAP}/report.json" | sort -u | wc -l)"
_t_eq "12" "${checks_seen}" "collect_snapshot emits one entry per probe"

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${SNAP}/report.json"; then
    _t_pass "collect_snapshot writes parseable JSON"
else
    _t_fail "collect_snapshot produced invalid JSON"
fi

case "$(cat "${SNAP}/report.json")" in
    *'"device":"test-serial"'*) _t_pass "collect_snapshot records the device serial" ;;
    *) _t_fail "collect_snapshot did not record the serial" ;;
esac

monitor_print_summary "${SNAP}" >/dev/null
_t_pass "print_summary renders an existing report"

monitor_print_summary "${TEST_TMPDIR}/no-such-dir" >/dev/null
_t_pass "print_summary warns and returns 0 for a missing report"

if monitor_severity_exit "${TEST_TMPDIR}/no-such-dir"; then
    _t_pass "severity_exit returns 0 when no report exists"
else
    _t_fail "severity_exit should return 0 for a missing report"
fi

# The all-fatal snapshot above must exit nonzero.
if ! monitor_severity_exit "${SNAP}"; then
    _t_pass "severity_exit returns 1 when a check is fatal"
else
    _t_fail "severity_exit should return 1 on a fatal check"
fi

printf '%s\n' '{"checks":[{"check":"x","status":"ok","source":"s","message":"mentions fatal and error","repairable":false}]}' \
    >"${SNAP}/report.json"
if monitor_severity_exit "${SNAP}"; then
    _t_pass "severity_exit ignores fatal/error words in free text"
else
    _t_fail "severity_exit should only inspect the JSON status field"
fi
