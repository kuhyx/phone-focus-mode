#!/usr/bin/env bash
# lib/tests/monitor_cases_health.sh — assertions for monitor.sh's own helpers
# (JSON escaping, hosts-target resolution, pidfile/liveness, format
# indicators) and the device-health probes in monitor_checks_health.sh.
#
# Sourced by test_monitor.sh after monitor_harness.sh, which owns the fake
# device, the subject, and the PASS/FAIL counters this file adds to.
set -euo pipefail

# --- helpers under monitor.sh ----------------------------------------------

line="$(_mon_check "test_check" "ok" "some_cmd" "all good" "false")"
_t_eq "test_check" "$(_field "${line}" check)" "_mon_check outputs check name"
_t_eq "ok" "$(_field "${line}" status)" "_mon_check outputs status"

escaped="$(_mon_check 'a"b\c' "ok" "s" $'l1\nl2\r' "false")"
case "${escaped}" in
    *'a\"b\\c'*) _t_pass "_mon_check escapes quotes and backslashes" ;;
    *) _t_fail "_mon_check did not escape quotes/backslashes: ${escaped}" ;;
esac
case "${escaped}" in
    *'l1\nl2\r'*) _t_pass "_mon_check escapes newlines and carriage returns" ;;
    *) _t_fail "_mon_check did not escape newlines: ${escaped}" ;;
esac

_t_eq "a b" "$(_trim_output $'  a b \r\n')" "_trim_output strips CR and outer space"
_t_eq "" "$(_safe_adb_root_output "no-such-command")" "_safe_adb_root_output swallows failure"

# --- hosts target resolution ------------------------------------------------

_dev_reset
_t_eq "" "$(_monitor_resolve_hosts_target)" "resolve_hosts_target empty when no candidate exists"

_dev_reset
_dev_present /system/etc/hosts
_t_eq "/system/etc/hosts" "$(_monitor_resolve_hosts_target)" \
    "resolve_hosts_target short-circuits on the primary target"

_dev_reset
_dev_present /vendor/etc/hosts
_t_eq "/vendor/etc/hosts" "$(_monitor_resolve_hosts_target)" \
    "resolve_hosts_target falls through to the first existing candidate"

# --- pidfile and liveness ---------------------------------------------------

_dev_reset
_t_eq "" "$(_monitor_read_pidfile /data/local/tmp/focus_mode/daemon.pid)" \
    "read_pidfile empty when the pidfile is absent"

_dev_set pidfile_daemon 1234
_t_eq "1234" "$(_monitor_read_pidfile /data/local/tmp/focus_mode/daemon.pid)" \
    "read_pidfile returns the stored pid"

_dev_reset
if ! _monitor_pid_matches_script 999 "focus_daemon.sh"; then
    _t_pass "pid_matches_script fails when the pid is not alive"
else
    _t_fail "pid_matches_script should fail for a dead pid"
fi

_dev_pid 999
_dev_cmdline 999 "/system/bin/sh focus_daemon.sh"
if _monitor_pid_matches_script 999 "focus_daemon.sh"; then
    _t_pass "pid_matches_script succeeds when cmdline matches"
else
    _t_fail "pid_matches_script should succeed on a cmdline match"
fi

# A live pid whose cmdline is hidden is trusted anyway — the deliberate
# false-negative guard at monitor.sh's "Some Android shells hide cmdline".
_dev_reset
_dev_pid 777
if _monitor_pid_matches_script 777 "focus_daemon.sh"; then
    _t_pass "pid_matches_script trusts a live pid with unreadable cmdline"
else
    _t_fail "pid_matches_script should trust a live pid when cmdline is hidden"
fi

# --- format indicators ------------------------------------------------------

_dev_reset
FORMAT_INDICATORS=(
    "present|test -f /present"
    "missing-one|test -f /missing-one"
    "missing-two|test -f /missing-two"
)
_dev_present /present

mapfile -t missing < <(monitor_check_format_indicators)
_t_eq "2" "${#missing[@]}" "check_format_indicators reports only the missing ones"
_t_eq "missing-one missing-two" "${missing[*]}" "check_format_indicators names them in order"
_t_eq "2" "$(monitor_count_missing_format_indicators)" "count_missing_format_indicators counts them"

if monitor_is_formatted; then
    _t_pass "monitor_is_formatted true at the missing-indicator threshold"
else
    _t_fail "monitor_is_formatted should be true with 2 missing and threshold 2"
fi

_t_eq "fatal" "$(_field "$(_probe _check_format_indicators)" status)" \
    "_check_format_indicators is fatal at the threshold"

_dev_present /missing-one
_t_eq "warn" "$(_field "$(_probe _check_format_indicators)" status)" \
    "_check_format_indicators warns below the threshold"

_dev_present /missing-two
_t_eq "ok" "$(_field "$(_probe _check_format_indicators)" status)" \
    "_check_format_indicators is ok with none missing"

if ! monitor_is_formatted; then
    _t_pass "monitor_is_formatted false when nothing is missing"
else
    _t_fail "monitor_is_formatted should be false with no missing indicators"
fi

# The guard calls _fatal, which exits, so it runs in a child rather than by
# shadowing the function here: an inline redefinition is invoked only
# indirectly, so standalone the linter calls it dead (SC2329). The child's
# source comes from a quoted heredoc, as in dns_iptables_harness.sh — it is
# code for the *child* to expand, so $VAR must survive this file untouched.
_mh_bad_count() {
    MH_HARNESS="${SCRIPT_DIR}/monitor_harness.sh" bash <<'CHILD'
. "${MH_HARNESS}"
monitor_count_missing_format_indicators() { printf 'not-a-number\n'; }
monitor_is_formatted
CHILD
}

if ! _mh_bad_count 2>/dev/null; then
    _t_pass "monitor_is_formatted rejects a non-numeric count"
else
    _t_fail "monitor_is_formatted should abort on a non-numeric count"
fi

monitor_print_format_warning "missing-one" "missing-two"
_t_pass "monitor_print_format_warning renders without error"

# Reset for the probes below, which must see no format indicators. Read back
# immediately so the assignment has a reader in this file (SC2034).
FORMAT_INDICATORS=()
_t_eq "0" "${#FORMAT_INDICATORS[@]}" "format indicators reset before the health probes"

# --- battery ----------------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_battery)" status)" "battery warns when the level is unreadable"

_dev_set battery_level 5
_t_eq "warn" "$(_field "$(_probe _check_battery)" status)" "battery warns below the threshold"

_dev_set battery_level 80
_dev_set battery_health Good
_dev_set battery_temp 305
json="$(_probe _check_battery)"
_t_eq "ok" "$(_field "${json}" status)" "battery ok above the threshold"
case "$(_field "${json}" message)" in
    *"health Good"*) _t_pass "battery message carries health and temperature" ;;
    *) _t_fail "battery message lost health/temp: $(_field "${json}" message)" ;;
esac

# Health and temp missing must not demote the status; they render as unknown.
_dev_reset
_dev_set battery_level 80
case "$(_field "$(_probe _check_battery)" message)" in
    *"health unknown"*) _t_pass "battery reports unknown health without warning" ;;
    *) _t_fail "battery should render missing health as unknown" ;;
esac

# --- storage ----------------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_storage)" status)" "storage warns when both df paths fail"

_dev_set df_emulated 1000000
_t_eq "ok" "$(_field "$(_probe _check_storage)" status)" "storage falls back to /storage/emulated/0"

_dev_reset
_dev_set df_sdcard 1024
_t_eq "warn" "$(_field "$(_probe _check_storage)" status)" "storage warns below the MB threshold"

_dev_set df_sdcard 2000000
json="$(_probe _check_storage)"
_t_eq "ok" "$(_field "${json}" status)" "storage ok above the threshold"
_t_eq "Free storage: 1953 MB" "$(_field "${json}" message)" "storage converts KB to MB"

# --- daemons ----------------------------------------------------------------

readonly PIDFILE="/data/local/tmp/focus_mode/daemon.pid"

_dev_reset
json="$(_probe _check_daemon focus_daemon focus_daemon.sh "${PIDFILE}")"
_t_eq "error" "$(_field "${json}" status)" \
    "daemon errors when neither pidfile nor pgrep finds it"
# repairable drives whether the monitor offers to restart it, so it is pinned
# separately from the status: a dead daemon that reports itself unrepairable
# is reported but never fixed.
case "${json}" in
    *'"repairable":true'*) _t_pass "a dead daemon is marked repairable" ;;
    *) _t_fail "a dead daemon must be repairable: ${json}" ;;
esac

_dev_set pidfile_daemon 4321
_dev_pid 4321
_dev_cmdline 4321 "focus_daemon.sh"
json="$(_probe _check_daemon focus_daemon focus_daemon.sh "${PIDFILE}")"
_t_eq "ok" "$(_field "${json}" status)" "daemon ok via the pidfile"
_t_eq "focus_daemon running (PID 4321)" "$(_field "${json}" message)" "daemon names the pidfile pid"

# Stale pidfile, live process: the pgrep fallback is what must find it.
_dev_reset
_dev_set pidfile_daemon 4321
_dev_set pgrep_focus_daemon.sh 8888
_dev_pid 8888
json="$(_probe _check_daemon focus_daemon focus_daemon.sh "${PIDFILE}")"
_t_eq "ok" "$(_field "${json}" status)" "daemon ok via the pgrep fallback"
_t_eq "focus_daemon running (PID 8888)" "$(_field "${json}" message)" "daemon names the pgrep pid"

# pgrep reports a pid that has since exited — neither path may claim ok.
_dev_reset
_dev_set pgrep_focus_daemon.sh 8888
_t_eq "error" "$(_field "$(_probe _check_daemon focus_daemon focus_daemon.sh "${PIDFILE}")" status)" \
    "daemon errors when the pgrep pid is already dead"

# --- hosts daemon -----------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_hosts_daemon)" status)" \
    "hosts daemon skipped when the ROM has no hosts target"

_dev_present /system/etc/hosts
_t_eq "error" "$(_field "$(_probe _check_hosts_daemon)" status)" \
    "hosts daemon checked once a hosts target exists"

# --- launcher daemon --------------------------------------------------------

_dev_reset
_t_eq "warn" "$(_field "$(_probe _check_launcher_daemon)" status)" \
    "launcher daemon skipped when launcher is unconfigured"

_dev_reset
_dev_present /data/local/tmp/focus_mode/minimalist_launcher.activity
_t_eq "error" "$(_field "$(_probe _check_launcher_daemon)" status)" \
    "launcher daemon checked once a snapshot exists"

_dev_reset
_dev_present pkg_launcher
_t_eq "error" "$(_field "$(_probe _check_launcher_daemon)" status)" \
    "launcher daemon checked once the launcher is installed"
