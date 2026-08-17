#!/usr/bin/env bash
# lib/tests/ctl_cases_curfew.sh — assertions for the pure logic in the ctl
# libraries: the zero-stripping helper, the night-curfew window, and the
# seven pidfile helpers.
#
# Sourced by test_ctl_libs.sh after ctl_libs_harness.sh, which owns the stubs,
# the subjects and the PASS/FAIL counters this file adds to.
set -euo pipefail

# --- _ctl_dec ---------------------------------------------------------------

# Zero-padded times must not reach shell arithmetic as octal: "0830" is not a
# valid octal number and would abort the comparison mid-check.
_t_eq "830" "$(_ctl_dec 0830)" "_ctl_dec strips the leading zero from 0830"
_t_eq "500" "$(_ctl_dec 0500)" "_ctl_dec strips the leading zero from 0500"
_t_eq "0" "$(_ctl_dec 0000)" "_ctl_dec keeps a single digit for midnight"
_t_eq "2300" "$(_ctl_dec 2300)" "_ctl_dec leaves an unpadded time alone"
_t_eq "9" "$(_ctl_dec 0009)" "_ctl_dec strips several leading zeros"

# --- ctl_is_curfew_now ------------------------------------------------------

# The window wraps past midnight, which a naive start<=now<end comparison gets
# exactly backwards: it would report curfew all day and never at night.
NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"

for t in 2300 2359 0000 0430; do
    _set_now "${t}"
    if ctl_is_curfew_now; then
        _t_pass "curfew is open at ${t} inside the wrapping window"
    else
        _t_fail "curfew should be open at ${t}"
    fi
done

for t in 0500 1200 2259; do
    _set_now "${t}"
    if ! ctl_is_curfew_now; then
        _t_pass "curfew is closed at ${t} outside the wrapping window"
    else
        _t_fail "curfew should be closed at ${t}"
    fi
done

# A same-day window includes its start and excludes its end.
NIGHT_CURFEW_START="0900"
NIGHT_CURFEW_END="1700"

_set_now "0900"
if ctl_is_curfew_now; then
    _t_pass "a same-day window includes its start minute"
else
    _t_fail "0900 should be inside a 0900-1700 window"
fi

_set_now "1700"
if ! ctl_is_curfew_now; then
    _t_pass "a same-day window excludes its end minute"
else
    _t_fail "1700 should be outside a 0900-1700 window"
fi

_set_now "1200"
if ctl_is_curfew_now; then
    _t_pass "a same-day window is open midway through"
else
    _t_fail "1200 should be inside a 0900-1700 window"
fi

NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"
_t_eq "2300-0500" "${NIGHT_CURFEW_START}-${NIGHT_CURFEW_END}" \
    "the wrapping window is restored for the clock cases"

# A broken clock must fail OPEN: reporting permanent curfew because `date`
# misbehaved would lock the phone down with no way to see why.
for bad in "not-a-time" "" "12:00"; do
    _set_now "${bad}"
    if ! ctl_is_curfew_now; then
        _t_pass "a malformed clock ('${bad}') reads as no curfew"
    else
        _t_fail "a malformed clock ('${bad}') must not enable the curfew"
    fi
done

# --- the two copies must agree ---------------------------------------------

# daemon_location.sh carries its own is_curfew_now. The phone's daemon and its
# control script disagreeing about whether it is night is a silent, confusing
# failure, so the copies are compared directly rather than trusted to match.
_curfew_table() {
    local answers="" t=""
    for t in 2259 2300 2359 0000 0430 0500 1200; do
        _set_now "${t}"
        if "$1"; then answers="${answers}1"; else answers="${answers}0"; fi
    done
    printf '%s' "${answers}"
}

ctl_answers="$(_curfew_table ctl_is_curfew_now)"

(
    # Sourced in a subshell: daemon_location.sh defines is_curfew_now and
    # curfew_active, and only the former is wanted here.
    # shellcheck source=../../daemon_location.sh
    . "${PHONE_DIR}/daemon_location.sh"
    _curfew_table is_curfew_now
) >"${RUN}/state/daemon_answers"

_t_eq "${ctl_answers}" "$(cat "${RUN}/state/daemon_answers")" \
    "ctl_is_curfew_now and daemon is_curfew_now agree on every boundary"
# 2259 closed, 2300/2359/0000/0430 open, 0500 closed (end is exclusive),
# 1200 closed. Spelled out so the agreement check above cannot pass by
# both copies being wrong in the same way.
_t_eq "0111100" "${ctl_answers}" "the shared window answers match the 2300-0500 spec"

# --- the seven pid helpers --------------------------------------------------

# One table rather than seven near-identical blocks: the duplication is in the
# subject, and repeating it here would add nothing and trip the jscpd gate.
_pid_case() {
    local fn="$1" var="$2"
    local file="${RUN}/state/${fn}.pid"
    # printf -v assigns to a name held in a variable without eval, which the
    # repo's shell rules forbid.
    printf -v "${var}" '%s' "${file}"

    rm -f "${file}"
    _t_eq "" "$(${fn})" "${fn} is empty with no pidfile"

    printf '999999\n' >"${file}"
    _t_eq "" "$(${fn})" "${fn} is empty when the recorded pid is dead"

    printf '%s\n' "$$" >"${file}"
    _t_eq "$$" "$(${fn})" "${fn} returns a live pid"
}

_pid_case hosts_enforcer_pid HOSTS_PIDFILE
_pid_case dns_enforcer_pid DNS_PIDFILE
_pid_case launcher_enforcer_pid LAUNCHER_PIDFILE
_pid_case workout_detector_pid WORKOUT_PIDFILE
_pid_case curfew_enforcer_pid CURFEW_PIDFILE
_pid_case tether_enforcer_pid TETHER_PIDFILE
_pid_case daemon_pid PIDFILE
