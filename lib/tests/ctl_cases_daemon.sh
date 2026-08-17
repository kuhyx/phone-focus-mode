#!/usr/bin/env bash
# lib/tests/ctl_cases_daemon.sh — assertions for focus_ctl.sh's own commands:
# status, disable, recheck, log, notif-status and the whitelist iterator.
#
# Sourced by test_ctl_libs.sh after ctl_cases_commands.sh, which owns the
# table helpers and the counters. Split out to stay under the 250-line cap.
set -euo pipefail

# --- cmd_status --------------------------------------------------------------

# The location block is the only part that talks to the device; the rest is a
# report of files the tests control.
rm -f "${PIDFILE}"
printf 'focus\n' >"${MODE_FILE}"
printf 'com.a\ncom.b\n' >"${DISABLED_APPS_FILE}"
_seed_out dumpsys 'last location=Location[fused 52.2297,21.0122 hAcc=12]'
out="$(cmd_status 2>&1 || true)"

case "${out}" in
    *"Mode:     focus"*) _t_pass "status reports the recorded mode" ;;
    *) _t_fail "status must report the mode from MODE_FILE" ;;
esac
case "${out}" in
    *"Location: 52.2297, 21.0122"*) _t_pass "status reports the current fix" ;;
    *) _t_fail "status must report the current location" ;;
esac
# The distance is the THIRD copy of the Haversine in this repo. Asserting only
# that some number is printed lets a wrong Earth radius through, so the value
# is checked: HOME_LAT/HOME_LON are Warsaw and the seeded fix is ~4.3 km away.
case "${out}" in
    *"Distance: "*"m from home"*) _t_pass "status reports a distance from home" ;;
    *) _t_fail "status must report the distance from home" ;;
esac
status_dist="$(printf '%s\n' "${out}" | sed -n 's/^Distance: \([0-9]*\)m from home$/\1/p')"
if [[ "${status_dist}" -ge 4000 && "${status_dist}" -le 4600 ]]; then
    _t_pass "status computes a correct distance (${status_dist} m)"
else
    _t_fail "status distance should be ~4300 m, got '${status_dist}'"
fi
case "${out}" in
    *com.a*) _t_pass "status lists the apps focus mode disabled" ;;
    *) _t_fail "status must list the disabled apps" ;;
esac

# No fix available must say so rather than print an empty distance.
rm -f "${DEV}/out_dumpsys"
case "$(cmd_status 2>&1 || true)" in
    *"Location: unavailable"*) _t_pass "status reports an unavailable location" ;;
    *) _t_fail "status must report when no fix is available" ;;
esac

# An empty disabled list reads as a sentence, not as blank output.
: >"${DISABLED_APPS_FILE}"
case "$(cmd_status 2>&1 || true)" in
    *"No apps currently disabled"*) _t_pass "status states when nothing is disabled" ;;
    *) _t_fail "status must state when nothing is disabled" ;;
esac

# An unset mode file is reported as unknown, not as an empty field.
rm -f "${MODE_FILE}"
case "$(cmd_status 2>&1 || true)" in
    *"Mode:     unknown"*) _t_pass "status reports an unknown mode explicitly" ;;
    *) _t_fail "status must report an unknown mode explicitly" ;;
esac

# --- cmd_disable -------------------------------------------------------------

# The restore pass must re-enable every recorded package and then clear the
# record, or the next run would try to re-enable them all again.
printf 'com.one\ncom.two\n' >"${DISABLED_APPS_FILE}"
_reset_calls
_run_quiet cmd_disable
_t_eq "2" "$(_calls | grep -c '^pm enable')" "disable re-enables every recorded app"
if [[ -s "${DISABLED_APPS_FILE}" ]]; then
    _t_fail "disable left the record of disabled apps in place"
else
    _t_pass "disable clears the record once everything is restored"
fi

: >"${DISABLED_APPS_FILE}"
case "$(cmd_disable 2>&1 || true)" in
    *"No apps to re-enable"*) _t_pass "disable states when there is nothing to restore" ;;
    *) _t_fail "disable must state when there is nothing to restore" ;;
esac

# --- cmd_recheck / cmd_log / cmd_notif_status --------------------------------

# A recheck with no daemon has nothing to wake, so it must refuse rather than
# leave a trigger file that nothing will ever consume.
rm -f "${RECHECK_TRIGGER}" "${PIDFILE}"
case "$(cmd_recheck 2>&1 || true)" in
    *"not running"*) _t_pass "recheck refuses when the daemon is not running" ;;
    *) _t_fail "recheck must refuse when the daemon is not running" ;;
esac
if [[ -e "${RECHECK_TRIGGER}" ]]; then
    _t_fail "recheck left a trigger nothing will consume"
else
    _t_pass "recheck writes no trigger when the daemon is down"
fi

/usr/bin/sleep 30 &
_recheck_victim=$!
printf '%s\n' "${_recheck_victim}" >"${PIDFILE}"
_run_quiet cmd_recheck
if [[ -e "${RECHECK_TRIGGER}" ]]; then
    _t_pass "recheck touches the trigger the daemon polls for"
else
    _t_fail "recheck must create the trigger file"
fi
kill "${_recheck_victim}" 2>/dev/null || true
wait "${_recheck_victim}" 2>/dev/null || true
rm -f "${PIDFILE}"

printf 'line one\nline two\n' >"${LOG_FILE}"
case "$(cmd_log 2>&1 || true)" in
    *"line two"*) _t_pass "log shows the daemon log" ;;
    *) _t_fail "log must show the daemon log" ;;
esac

printf '{"mode":"focus"}\n' >"${STATUS_FILE}"
case "$(cmd_notif_status 2>&1 || true)" in
    *focus*) _t_pass "notif-status shows the companion snapshot" ;;
    *) _t_fail "notif-status must show the status snapshot" ;;
esac

# --- iter_whitelist_packages -------------------------------------------------

# The list is a multi-line quoted string with comments and section headings;
# only real package names may come out, or the sweep would try to disable a
# heading like "---".
_saved_whitelist="${WHITELIST}"
# The undotted token and the comment must each be caught by their OWN filter,
# so the fixture separates them: "# com.commented.out" is a comment whose
# first token IS dotted and IS charset-clean, so only the comment check can
# reject it. "not-a-package" is undotted, so only the dot check rejects it.
# A fixture without both leaves each filter deletable with no test failing.
WHITELIST="
# a comment

# --- a section heading ---
# com.commented.out
com.real.one
  com.real.two
notapackage
com.bad!name
com.real.three trailing prose
"
_t_eq "com.real.one com.real.two com.real.three" \
    "$(iter_whitelist_packages | tr '\n' ' ' | sed 's/ $//')" \
    "iter_whitelist_packages emits only dotted package names"

# The two rejections are asserted separately, because the combined list above
# passes even if only one filter is doing any work. Captured ONCE here, before
# the fixture is replaced below: re-running the function after that would
# assert against a list holding neither an undotted token nor a comment, and
# would pass with both filters deleted.
whitelist_out="$(iter_whitelist_packages)"
case "${whitelist_out}" in
    *"notapackage"*) _t_fail "an undotted token was emitted as a package" ;;
    *) _t_pass "an undotted token is rejected by the dot check" ;;
esac
case "${whitelist_out}" in
    *"com.bad!name"*) _t_fail "a package with illegal characters was emitted" ;;
    *) _t_pass "an illegal character is rejected by the charset check" ;;
esac
case "${whitelist_out}" in
    *"com.commented.out"*) _t_fail "a commented-out package name was emitted" ;;
    *) _t_pass "a comment line is rejected even when its token looks valid" ;;
esac
# A comment whose first token IS dotted would slip past the dot check alone,
# so the comment filter has to be doing the work on its own.
WHITELIST="
# com.commented.out is deliberately disabled
com.real.only
"
_t_eq "com.real.only" "$(iter_whitelist_packages | tr '\n' ' ' | sed 's/ $//')" \
    "a commented-out package name is not emitted"
WHITELIST="${_saved_whitelist}"
