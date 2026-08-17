#!/usr/bin/env bash
# lib/tests/daemon_cases_sweep.sh — assertions for the focus-mode transitions
# in daemon_apps.sh: the sweep that disables non-whitelisted packages, the
# restore pass, and the reconciliation that brings back anything that has
# since become allowed.
#
# Sourced by test_daemon_libs.sh after daemon_cases_apps.sh, which owns
# _seed_lists and the counters. Split out to stay under the 250-line cap.
set -euo pipefail

# --- enable_focus_mode ------------------------------------------------------

_reset_dev
_seed_lists
CURRENT_MODE="normal"
: >"${DISABLED_APPS_FILE}"
_seed_packages com.allowed.day com.random.one com.random.two
: >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode

_t_eq "focus" "${CURRENT_MODE}" "entering focus mode records the mode"
disabled="$(_disabled | sort | tr '\n' ' ' | sed 's/ $//')"
_t_eq "com.random.one com.random.two" "${disabled}" \
    "focus mode disables exactly the non-whitelisted packages"

# Both packages, not just the first. The loop feeding pm reads its list by
# redirect precisely so pm cannot drain its stdin — this assertion is what
# would catch that regression.
_t_eq "2" "$(_disabled | wc -l)" "focus mode processes every package, not just the first"

recorded="$(sort "${DISABLED_APPS_FILE}" | tr '\n' ' ' | sed 's/ $//')"
_t_eq "com.random.one com.random.two" "${recorded}" \
    "focus mode records what it disabled so it can be undone"

# Blocked system apps are disabled too, from their own list.
_reset_dev
_seed_lists
CURRENT_MODE="normal"
: >"${DISABLED_APPS_FILE}"
_seed_packages com.allowed.day
printf 'com.android.browser\ncom.android.other\n' >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode
case "$(_disabled)" in
    *com.android.browser*) _t_pass "focus mode disables blocked system apps" ;;
    *) _t_fail "blocked system apps must be disabled" ;;
esac
_t_eq "2" "$(_disabled | wc -l)" "every blocked system app is processed"

# A package pm refuses to disable must not be recorded as disabled, or the
# restore pass would claim to re-enable something it never touched.
_reset_dev
_seed_lists
CURRENT_MODE="normal"
: >"${DISABLED_APPS_FILE}"
_seed_packages com.random.one com.stubborn
printf 'com.stubborn\n' >"${DEV}/pm_undisableable"
: >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode
if grep -qx "com.stubborn" "${DISABLED_APPS_FILE}"; then
    _t_fail "a package pm refused to disable was recorded as disabled"
else
    _t_pass "only packages pm actually disabled are recorded"
fi

# Re-entering focus mode must not wipe the record of what is already disabled.
_reset_dev
_seed_lists
CURRENT_MODE="focus"
printf 'com.already.off\n' >"${DISABLED_APPS_FILE}"
_seed_packages com.allowed.day
: >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode
if grep -qx "com.already.off" "${DISABLED_APPS_FILE}"; then
    _t_pass "a repeat sweep keeps the existing disabled record"
else
    _t_fail "a repeat sweep must not wipe the disabled record"
fi

# --- disable_focus_mode -----------------------------------------------------

_reset_dev
CURRENT_MODE="focus"
printf 'com.random.one\ncom.random.two\n' >"${DISABLED_APPS_FILE}"
disable_focus_mode

_t_eq "normal" "${CURRENT_MODE}" "leaving focus mode records the mode"
_t_eq "com.random.one com.random.two" \
    "$(_enabled | sort | tr '\n' ' ' | sed 's/ $//')" \
    "leaving focus mode re-enables everything it disabled"
_t_eq "2" "$(_enabled | wc -l)" "every disabled package is re-enabled, not just the first"

# Already normal: nothing to do, and nothing should be touched.
_reset_dev
CURRENT_MODE="normal"
printf 'com.random.one\n' >"${DISABLED_APPS_FILE}"
disable_focus_mode
_t_eq "" "$(_enabled)" "leaving focus mode is a no-op when already normal"

# --- reconcile_disabled_apps ------------------------------------------------

# A package that has since become allowed must be brought back, and dropped
# from the record — otherwise it stays disabled forever.
_reset_dev
_seed_lists
printf 'com.allowed.day\ncom.random.one\n' >"${DISABLED_APPS_FILE}"
reconcile_disabled_apps

case "$(_enabled)" in
    *com.allowed.day*) _t_pass "reconciliation re-enables a now-allowed package" ;;
    *) _t_fail "a package that became allowed must be re-enabled" ;;
esac
_t_eq "com.random.one" "$(cat "${DISABLED_APPS_FILE}")" \
    "reconciliation keeps only the packages that are still blocked"
case "$(_log)" in
    *"Re-enabled allowed app during state reconciliation"*)
        _t_pass "reconciliation logs what it restored" ;;
    *) _t_fail "reconciliation should log the packages it restored" ;;
esac

# install-existing runs before enable: a package removed for user 0 has to be
# reinstalled for that user before it can be enabled at all.
calls="$(_calls)"
inst="$(printf '%s\n' "${calls}" | grep -n "install-existing" | head -1 | cut -d: -f1)"
en="$(printf '%s\n' "${calls}" | grep -n "^pm enable com.allowed.day" | head -1 | cut -d: -f1)"
if [[ -n "${inst}" && -n "${en}" && "${en}" -gt "${inst}" ]]; then
    _t_pass "reconciliation reinstalls for user 0 before enabling"
else
    _t_fail "install-existing must precede enable"
fi

# No record file at all is a fresh install, not an error. The call is guarded
# because the bare `return` propagates the failed [ -f ] status; the daemon
# runs without set -e so that is harmless there, but it would abort this file.
_reset_dev
_seed_lists
rm -f "${DISABLED_APPS_FILE}"
reconcile_disabled_apps || true
_t_eq "" "$(_enabled)" "reconciliation is a no-op with no disabled record"

if [[ -f "${STATE_DIR}/disabled_by_focus.tmp" ]]; then
    _t_fail "reconciliation left its temp file behind"
else
    _t_pass "reconciliation moves its temp file into place"
fi

# A re-sweep that finds apps the user re-enabled must say so: silence here
# would hide the single most useful signal that enforcement is being fought.
_reset_dev
_seed_lists
CURRENT_MODE="focus"
: >"${DISABLED_APPS_FILE}"
_seed_packages com.random.one
: >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode
case "$(_log)" in
    *"re-disabled 1 apps"*) _t_pass "a re-sweep reports what the user re-enabled" ;;
    *) _t_fail "a re-sweep must report re-disabled apps" ;;
esac

# A re-sweep with nothing to do stays quiet, or the log fills with noise every
# tick and the line above stops carrying information.
_reset_dev
_seed_lists
CURRENT_MODE="focus"
printf 'com.random.one\n' >"${DISABLED_APPS_FILE}"
_seed_packages com.allowed.day
: >"${STATE_DIR}/blocked_sys.txt"
enable_focus_mode
if _log | grep -q "re-sweep"; then
    _t_fail "a re-sweep with nothing to do must not log"
else
    _t_pass "a quiet re-sweep stays quiet"
fi
