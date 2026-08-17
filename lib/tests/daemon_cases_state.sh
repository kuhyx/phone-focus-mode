#!/usr/bin/env bash
# lib/tests/daemon_cases_state.sh — assertions for daemon_state.sh: the state
# files derived from config, the cached default intent handlers, and the JSON
# status snapshot the companion app reads.
#
# Sourced by test_daemon_libs.sh after daemon_libs_harness.sh, which owns the
# stubs, the subjects and the PASS/FAIL counters this file adds to.
set -euo pipefail

# `settings` is only reached from refresh_default_handlers; stubbed here
# rather than in the harness because these are its only callers.
cat >"${RUN}/bin/settings" <<'STUB'
#!/usr/bin/env bash
printf 'settings %s\n' "$*" >>"${DEV}/calls.log"
key="${*: -1}"
[[ -f "${DEV}/setting_${key}" ]] && cat "${DEV}/setting_${key}"
exit 0
STUB
chmod +x "${RUN}/bin/settings"

# --- build_whitelist_file ---------------------------------------------------

_reset_dev
WHITELIST="com.one
com.two
# a comment

  com.three  "
build_whitelist_file

parsed="$(cat "${STATE_DIR}/whitelist.txt")"
_t_eq "com.one com.two com.three" "$(printf '%s' "${parsed}" | tr '\n' ' ' | sed 's/ $//')" \
    "whitelist drops comments and blanks and trims whitespace"

# The floor warning exists because a stray quote in config.sh silently
# truncates the WHITELIST string; a short list must be loud, not silent.
case "$(_log)" in
    *"WARN: whitelist suspiciously small"*) _t_pass "a short whitelist warns loudly" ;;
    *) _t_fail "a whitelist under the floor must warn" ;;
esac
case "$(_log)" in
    *"Whitelist parsed: 3 entries"*) _t_pass "whitelist logs the parsed entry count" ;;
    *) _t_fail "whitelist should log its entry count" ;;
esac

# A healthy list must not cry wolf, or the warning stops meaning anything.
_reset_dev
WHITELIST="$(for i in $(seq 1 40); do printf 'com.app%02d\n' "$i"; done)"
build_whitelist_file
if _log | grep -q "WARN: whitelist suspiciously small"; then
    _t_fail "a 40-entry whitelist must not warn"
else
    _t_pass "a healthy whitelist does not warn"
fi
_t_eq "40" "$(wc -l <"${STATE_DIR}/whitelist.txt")" "whitelist keeps every entry"
_t_eq "40" "$(printf '%s\n' "${WHITELIST}" | wc -l)" \
    "the seeded whitelist really held 40 entries"

# --- build_night_whitelist_file --------------------------------------------

_reset_dev
NIGHT_WHITELIST="com.night.one
# comment
com.night.two"
build_night_whitelist_file
_t_eq "com.night.one com.night.two" \
    "$(tr '\n' ' ' <"${STATE_DIR}/night_whitelist.txt" | sed 's/ $//')" \
    "night whitelist parses like the day list"
case "$(_log)" in
    *"WARN: night whitelist suspiciously small"*) _t_pass "a short night whitelist warns" ;;
    *) _t_fail "a night whitelist under its floor must warn" ;;
esac

# The two lists have different floors (30 and 10), so a list that is fine for
# one must not be judged by the other's threshold.
_reset_dev
NIGHT_WHITELIST="$(for i in $(seq 1 12); do printf 'com.night%02d\n' "$i"; done)"
build_night_whitelist_file
_t_eq "12" "$(printf '%s\n' "${NIGHT_WHITELIST}" | wc -l)" \
    "the seeded night whitelist really held 12 entries"
if _log | grep -q "WARN: night whitelist"; then
    _t_fail "12 night entries is above the night floor and must not warn"
else
    _t_pass "the night whitelist uses its own lower floor"
fi

# --- build_sysprotect_file / build_blocked_sys_file ------------------------

_reset_dev
SYSTEM_NEVER_DISABLE="com.android.
com.google.android.gms"
build_sysprotect_file
_t_eq "2" "$(wc -l <"${STATE_DIR}/sysprotect.txt")" "sysprotect writes every prefix"
_t_eq "2" "$(printf '%s\n' "${SYSTEM_NEVER_DISABLE}" | wc -l)" \
    "the seeded sysprotect list really held two prefixes"

BLOCKED_SYSTEM_APPS="com.android.browser
# not this one
com.android.chrome"
build_blocked_sys_file
_t_eq "com.android.browser com.android.chrome" \
    "$(tr '\n' ' ' <"${STATE_DIR}/blocked_sys.txt" | sed 's/ $//')" \
    "blocked-system list drops comments"
_t_eq "3" "$(printf '%s\n' "${BLOCKED_SYSTEM_APPS}" | wc -l)" \
    "the seeded blocked-system list really held three lines"

# --- refresh_default_handlers ----------------------------------------------

_reset_dev
printf 'Activity Resolver Table:\ncom.launcher.home/.MainActivity\n' >"${DEV}/cmd_out"
printf 'com.dialer.app\n' >"${DEV}/setting_get"
printf 'com.sms.app\n' >"${DEV}/setting_sms_default_application"
printf 'com.ime.app/.Service\n' >"${DEV}/setting_default_input_method"
refresh_default_handlers

handlers="$(cat "${STATE_DIR}/default_handlers.txt")"
case "${handlers}" in
    *com.launcher.home*) _t_pass "default handlers include the launcher" ;;
    *) _t_fail "default handlers must include the launcher" ;;
esac

# The IME is the load-bearing one: pm disable-user on the active keyboard
# survives a reboot, so a 1am reboot would leave no way to type a recovery
# command. It has to be protected day and night.
case "${handlers}" in
    *com.ime.app*) _t_pass "default handlers include the active keyboard" ;;
    *) _t_fail "the active IME must be protected or a reboot locks you out" ;;
esac

# Only the package part of the IME component is usable as a package name.
if grep -q "com.ime.app/" "${STATE_DIR}/default_handlers.txt"; then
    _t_fail "the IME component suffix leaked into the package list"
else
    _t_pass "the IME is recorded as a package, not a component"
fi

# A literal "null" from the settings provider is an absent value, not a
# package, and must never be written as one.
_reset_dev
printf 'Activity Resolver Table:\ncom.launcher.home/.MainActivity\n' >"${DEV}/cmd_out"
printf 'null\n' >"${DEV}/setting_sms_default_application"
printf 'null\n' >"${DEV}/setting_default_input_method"
refresh_default_handlers
if grep -qx "null" "${STATE_DIR}/default_handlers.txt"; then
    _t_fail "a literal null was recorded as a default handler"
else
    _t_pass "a null settings value is not recorded as a handler"
fi

if [[ -f "${STATE_DIR}/default_handlers.txt.tmp" ]]; then
    _t_fail "refresh left its temp file behind"
else
    _t_pass "refresh cleans up its temp file"
fi

# The browser is tracked separately, because during curfew the whole point is
# to disable browsers — the default-handler guard must not resurrect them.
if [[ -f "${STATE_DIR}/default_browser.txt" ]]; then
    _t_pass "the default browser is tracked in its own file"
else
    _t_fail "the default browser must be tracked separately"
fi

# --- is_default_handler -----------------------------------------------------

_reset_dev
printf 'com.launcher.home\ncom.ime.app\n' >"${STATE_DIR}/default_handlers.txt"
if is_default_handler "com.launcher.home"; then
    _t_pass "a listed package is recognised as a default handler"
else
    _t_fail "a listed package must be recognised"
fi
if ! is_default_handler "com.other.app"; then
    _t_pass "an unlisted package is not a default handler"
else
    _t_fail "an unlisted package must not be recognised"
fi

# Exact match only: a prefix would protect far more than intended.
if ! is_default_handler "com.launcher"; then
    _t_pass "default-handler matching is exact, not by prefix"
else
    _t_fail "a prefix must not match a default handler"
fi

# --- write_status_snapshot --------------------------------------------------

_reset_dev
printf 'com.a\ncom.b\ncom.c\n' >"${DISABLED_APPS_FILE}"
_set_now "1200"
write_status_snapshot "focus" "52.2297" "21.0122" "42" "100"

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${STATUS_FILE}"; then
    _t_pass "the status snapshot is parseable JSON"
else
    _t_fail "the status snapshot must be valid JSON"
fi

_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "${STATUS_FILE}" "$1"
}

_t_eq "focus" "$(_field mode)" "the snapshot records the mode"
_t_eq "52.2297" "$(_field lat)" "the snapshot records the latitude"
_t_eq "42" "$(_field distance_m)" "the snapshot records the distance"
_t_eq "100" "$(_field threshold_m)" "the snapshot records the threshold"
_t_eq "3" "$(_field disabled_count)" "the snapshot counts the disabled apps"

# Absent coordinates must still produce valid JSON: distance and threshold
# become null, not an empty token that would break the companion app's parse.
_reset_dev
: >"${DISABLED_APPS_FILE}"
write_status_snapshot "normal" "" "" "" ""
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${STATUS_FILE}"; then
    _t_pass "a snapshot with no fix is still valid JSON"
else
    _t_fail "a snapshot with no fix must remain valid JSON"
fi
_t_eq "None" "$(_field distance_m)" "a missing distance is written as JSON null"
_t_eq "0" "$(_field disabled_count)" "an empty disabled list counts as zero"

# The curfew flags are what the companion app renders, so they must track the
# files rather than being hardcoded.
_reset_dev
touch "${CURFEW_OVERRIDE_FILE}"
write_status_snapshot "normal" "" "" "" ""
_t_eq "1" "$(_field curfew_override)" "the snapshot reports an active override"
_t_eq "0" "$(_field curfew)" "curfew reads inactive while overridden"
rm -f "${CURFEW_OVERRIDE_FILE}"

_reset_dev
touch "${CURFEW_FORCE_FILE}"
write_status_snapshot "normal" "" "" "" ""
_t_eq "1" "$(_field curfew_force)" "the snapshot reports the force flag"
_t_eq "1" "$(_field curfew)" "curfew reads active while forced"
rm -f "${CURFEW_FORCE_FILE}"

if [[ -f "${STATUS_FILE}.tmp" ]]; then
    _t_fail "the snapshot left its temp file behind"
else
    _t_pass "the snapshot moves its temp file into place"
fi

# An unwritable status file must not take the daemon down with it: the
# snapshot is for the companion app, and losing it is not worth losing
# enforcement. Proven by pointing STATUS_FILE into a directory that does not
# exist, so the redirect fails.
_reset_dev
_saved_status="${STATUS_FILE}"
STATUS_FILE="${RUN}/state/no-such-dir/status.json"
if write_status_snapshot "focus" "" "" "" ""; then
    _t_pass "an unwritable snapshot returns success rather than aborting"
else
    _t_fail "a failed snapshot write must not propagate a failure"
fi
STATUS_FILE="${_saved_status}"
