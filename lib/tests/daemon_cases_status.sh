#!/usr/bin/env bash
# lib/tests/daemon_cases_status.sh — assertions for write_status_snapshot, the
# JSON file the companion notification app polls.
#
# Sourced by test_daemon_libs.sh after daemon_cases_state.sh, which owns the
# stubs and counters. Split out to stay under the 250-line cap.
set -euo pipefail

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
