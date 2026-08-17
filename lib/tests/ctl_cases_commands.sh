#!/usr/bin/env bash
# lib/tests/ctl_cases_commands.sh — assertions for focus_ctl.sh's subcommands,
# against the device stubs in test_ctl_libs.sh.
#
# The start/stop/status trio is the same shape in all seven enforcer
# libraries, so it is driven through tables rather than seven near-identical
# blocks: the duplication is in the subject, and repeating it here would add
# nothing and trip the jscpd gate. The per-enforcer specifics that tables
# cannot express get their own cases below.
set -euo pipefail

# Run a subcommand for its side effects only. These are CLI entry points whose
# exit status is not part of their contract, and an unguarded nonzero return
# aborts the whole file under set -e.
_run_quiet() {
    "$1" >/dev/null 2>&1 || return 0
}

# _start_case <cmd> <pid-fn> <pidfile-var> <label>
#
# A start command must refuse when already running, and must report the
# failure rather than claim success when the daemon does not come up. The
# stubbed setsid never actually starts anything, so "came up" is modelled by
# the pidfile appearing.
_start_case() {
    local cmd="$1" pidvar="$2" label="$3"
    local file="${!pidvar}"

    printf '%s\n' "$$" >"${file}"
    _reset_calls
    case "$(${cmd} || true)" in
        *"already running"*) _t_pass "${label} refuses to start a second copy" ;;
        *) _t_fail "${label} must not start when already running" ;;
    esac
    if _calls | grep -q "^setsid"; then
        _t_fail "${label} launched a daemon that was already running"
    else
        _t_pass "${label} launches nothing when already running"
    fi

    rm -f "${file}"
    _reset_calls
    case "$(${cmd} 2>&1 || true)" in
        *ERROR*) _t_pass "${label} reports a daemon that failed to come up" ;;
        *) _t_fail "${label} must report a failed start, not claim success" ;;
    esac
    if _calls | grep -q "^setsid"; then
        _t_pass "${label} does try to launch when nothing is running"
    else
        _t_fail "${label} should have launched a daemon"
    fi
}

# _stop_case <cmd> <pidfile-var> <label>
#
# The live pid must NOT be $$: these commands call `kill -TERM "$pid"`, so
# seeding the test's own pid makes the suite signal itself and die silently
# mid-run. A disposable background process is used instead.
_stop_case() {
    local cmd="$1" pidvar="$2" label="$3"
    local file="${!pidvar}" victim=""

    rm -f "${file}"
    _reset_calls
    case "$(${cmd} 2>&1 || true)" in
        *"not running"*) _t_pass "${label} reports nothing to stop" ;;
        *) _t_fail "${label} must report that nothing is running" ;;
    esac

    /usr/bin/sleep 30 &
    victim=$!
    printf '%s\n' "${victim}" >"${file}"
    _reset_calls
    _run_quiet "${cmd}"
    # kill is a shell builtin, so no PATH stub can observe it. The effect is
    # what is asserted: the victim must no longer be alive afterwards.
    /usr/bin/sleep 0.2
    if kill -0 "${victim}" 2>/dev/null; then
        _t_fail "${label} left the running daemon alive"
        kill "${victim}" 2>/dev/null || true
    else
        _t_pass "${label} signals the running daemon"
    fi
    wait "${victim}" 2>/dev/null || true
    rm -f "${file}"
}

# _status_case <cmd> <pidfile-var> <label>
_status_case() {
    local cmd="$1" pidvar="$2" label="$3"
    local file="${!pidvar}"

    rm -f "${file}"
    case "$(${cmd} 2>&1 || true)" in
        *STOPPED*) _t_pass "${label} reports STOPPED with no daemon" ;;
        *) _t_fail "${label} must report STOPPED when nothing is running" ;;
    esac

    printf '%s\n' "$$" >"${file}"
    case "$(${cmd} 2>&1 || true)" in
        *RUNNING*) _t_pass "${label} reports RUNNING with a live daemon" ;;
        *) _t_fail "${label} must report RUNNING when the daemon is up" ;;
    esac
    rm -f "${file}"
}

# --- the four enforcers whose trio is uniform -------------------------------

_start_case cmd_hosts_start HOSTS_PIDFILE "hosts start"
_stop_case cmd_hosts_stop HOSTS_PIDFILE "hosts stop"
_status_case cmd_hosts_status HOSTS_PIDFILE "hosts status"

_start_case cmd_dns_start DNS_PIDFILE "dns start"
_stop_case cmd_dns_stop DNS_PIDFILE "dns stop"
_status_case cmd_dns_status DNS_PIDFILE "dns status"

_start_case cmd_launcher_start LAUNCHER_PIDFILE "launcher start"
_stop_case cmd_launcher_stop LAUNCHER_PIDFILE "launcher stop"
_status_case cmd_launcher_status LAUNCHER_PIDFILE "launcher status"

_start_case cmd_workout_start WORKOUT_PIDFILE "workout start"

# The workout detector needs the sqlite3 binary deploy.sh pushes alongside it.
# Missing, it must refuse rather than launch a detector that cannot read the
# StrongLifts database.
rm -f "${WORKOUT_PIDFILE}"
_saved_sqlite="${WORKOUT_SQLITE3_BIN}"
WORKOUT_SQLITE3_BIN="${RUN}/state/no-such-sqlite3"
_reset_calls
case "$(cmd_workout_start 2>&1 || true)" in
    *"missing or not executable"*) _t_pass "workout start refuses without sqlite3" ;;
    *) _t_fail "workout start must refuse when sqlite3 is missing" ;;
esac
if _calls | grep -q "^setsid"; then
    _t_fail "workout start launched a detector with no sqlite3"
else
    _t_pass "workout start launches nothing without sqlite3"
fi
WORKOUT_SQLITE3_BIN="${_saved_sqlite}"
_stop_case cmd_workout_stop WORKOUT_PIDFILE "workout stop"

_start_case cmd_curfew_start CURFEW_PIDFILE "curfew start"
_stop_case cmd_curfew_stop CURFEW_PIDFILE "curfew stop"

_start_case cmd_tether_start TETHER_PIDFILE "tether start"
_stop_case cmd_tether_stop TETHER_PIDFILE "tether stop"
_status_case cmd_tether_status TETHER_PIDFILE "tether status"

_start_case cmd_start PIDFILE "daemon start"
_stop_case cmd_stop PIDFILE "daemon stop"

# --- dns status: the chain report -------------------------------------------

# A missing firewall chain is the whole point of the check, so it must be
# reported as MISSING rather than as a zero-rule chain.
rm -f "${DNS_PIDFILE}"
_clear_chain iptables
_clear_chain ip6tables
out="$(cmd_dns_status 2>&1)"
case "${out}" in
    *"iptables ${DNS_IPT_CHAIN}: MISSING"*) _t_pass "dns status reports a missing v4 chain" ;;
    *) _t_fail "dns status must report a missing v4 chain" ;;
esac
case "${out}" in
    *"ip6tables ${DNS_IPT_CHAIN}: MISSING"*) _t_pass "dns status reports a missing v6 chain" ;;
    *) _t_fail "dns status must report a missing v6 chain" ;;
esac

_seed_chain iptables "$(printf -- '-A one\n-A two\n-A three')"
_seed_chain ip6tables "-A one"
out="$(cmd_dns_status 2>&1)"
case "${out}" in
    *"iptables ${DNS_IPT_CHAIN}: 3 rules"*) _t_pass "dns status counts the v4 rules" ;;
    *) _t_fail "dns status must count the v4 rules" ;;
esac
case "${out}" in
    *"ip6tables ${DNS_IPT_CHAIN}: 1 rules"*) _t_pass "dns status counts the v6 rules" ;;
    *) _t_fail "dns status must count the v6 rules" ;;
esac

# Private DNS is the setting the enforcer exists to hold down, so an unset
# value must read as <unset> rather than as an empty line.
_seed_out settings ""
case "$(cmd_dns_status 2>&1)" in
    *"private_dns_mode:      <unset>"*) _t_pass "dns status renders an unset mode explicitly" ;;
    *) _t_fail "dns status must render an unset private DNS mode" ;;
esac
rm -f "${DEV}/out_settings"

# --- curfew status and the override/force hooks -----------------------------

_set_now "0000"
rm -f "${CURFEW_PIDFILE}" "${CURFEW_OVERRIDE_FILE}" "${CURFEW_FORCE_FILE}"

cmd_curfew_test_on >/dev/null 2>&1
if [[ -e "${CURFEW_FORCE_FILE}" ]]; then
    _t_pass "curfew-test-on creates the force file"
else
    _t_fail "curfew-test-on must create the force file"
fi

cmd_curfew_test_off >/dev/null 2>&1
if [[ -e "${CURFEW_FORCE_FILE}" ]]; then
    _t_fail "curfew-test-off left the force file behind"
else
    _t_pass "curfew-test-off clears the force file"
fi

# The escape hatch: this is the 2am opt-out, so it must actually take effect.
cmd_curfew_off >/dev/null 2>&1
if [[ -e "${CURFEW_OVERRIDE_FILE}" ]]; then
    _t_pass "curfew-off creates the override that suspends the curfew"
else
    _t_fail "curfew-off must create the override file"
fi

cmd_curfew_on >/dev/null 2>&1
if [[ -e "${CURFEW_OVERRIDE_FILE}" ]]; then
    _t_fail "curfew-on left the override in place"
else
    _t_pass "curfew-on clears the override and re-arms the curfew"
fi

# --- tether test hooks ------------------------------------------------------

rm -f "${TETHER_FORCE_FILE}"
cmd_tether_test_on >/dev/null 2>&1
if [[ -e "${TETHER_FORCE_FILE}" ]]; then
    _t_pass "tether-test-on creates the force file"
else
    _t_fail "tether-test-on must create the force file"
fi

cmd_tether_test_off >/dev/null 2>&1
if [[ -e "${TETHER_FORCE_FILE}" ]]; then
    _t_fail "tether-test-off left the force file behind"
else
    _t_pass "tether-test-off clears the force file"
fi

# --- usage ------------------------------------------------------------------

usage_text="$(usage 2>&1)"
for sub in start stop status hosts-status dns-status launcher-status \
    workout-status curfew-status tether-status curfew-off; do
    case "${usage_text}" in
        *"${sub}"*) _t_pass "usage documents ${sub}" ;;
        *) _t_fail "usage must document ${sub}" ;;
    esac
done
