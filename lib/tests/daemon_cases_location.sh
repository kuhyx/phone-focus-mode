#!/usr/bin/env bash
# lib/tests/daemon_cases_location.sh — assertions for daemon_location.sh: the
# GPS fix, the Haversine distance, and the night-curfew window.
#
# Sourced by test_daemon_libs.sh after daemon_libs_harness.sh, which owns the
# stubs, the subjects and the PASS/FAIL counters this file adds to.
#
# The curfew window wraps past midnight (2300 -> 0500), which is the case a
# naive start<=now<end comparison gets exactly backwards: it would report
# curfew during the whole day and never at night.
set -euo pipefail

# --- get_location -----------------------------------------------------------

_reset_dev
_t_eq "" "$(get_location)" "location is empty when dumpsys reports no fix"

printf 'last location=Location[fused 52.2297,21.0122 hAcc=12]\n' >"${DEV}/dumpsys_out"
_t_eq "52.2297,21.0122" "$(get_location)" "location extracts a fused coordinate pair"

# Several fixes in one dump: the first is the freshest and the only one used.
printf 'Location[fused 52.2297,21.0122]\nLocation[gps 50.0000,19.0000]\n' >"${DEV}/dumpsys_out"
_t_eq "52.2297,21.0122" "$(get_location)" "location takes only the first fix"

# Too few decimal places is not a real fix and must not be matched, or the
# daemon would compute a distance from a truncated coordinate.
printf 'Location[fused 52.22,21.01]\n' >"${DEV}/dumpsys_out"
_t_eq "" "$(get_location)" "location ignores coordinates with too little precision"

printf 'Location[fused -33.8688,151.2093]\n' >"${DEV}/dumpsys_out"
_t_eq "-33.8688,151.2093" "$(get_location)" "location handles southern/negative coordinates"

# --- calc_distance ----------------------------------------------------------

_t_eq "0" "$(calc_distance 52.2297 21.0122 52.2297 21.0122)" \
    "distance from a point to itself is zero"

# Warsaw to Krakow is ~252 km. A wrong radius or a degrees/radians slip shows
# up here as an answer off by orders of magnitude, not a rounding difference.
km="$(( $(calc_distance 52.2297 21.0122 50.0647 19.9450) / 1000 ))"
if [[ "${km}" -ge 245 && "${km}" -le 260 ]]; then
    _t_pass "distance Warsaw-Krakow is ~252 km (got ${km} km)"
else
    _t_fail "distance Warsaw-Krakow should be ~252 km, got ${km} km"
fi

# One degree of latitude is ~111 km anywhere on the globe.
deg="$(calc_distance 0 0 1 0)"
if [[ "${deg}" -ge 110000 && "${deg}" -le 112000 ]]; then
    _t_pass "one degree of latitude is ~111 km (got ${deg} m)"
else
    _t_fail "one degree of latitude should be ~111 km, got ${deg} m"
fi

# Symmetry: the distance cannot depend on which point is called home.
_t_eq "$(calc_distance 52.2297 21.0122 50.0647 19.9450)" \
      "$(calc_distance 50.0647 19.9450 52.2297 21.0122)" \
    "distance is symmetric"

# A short hop must still register, since the geofence threshold is ~100 m.
near="$(calc_distance 52.2297 21.0122 52.2306 21.0122)"
if [[ "${near}" -ge 80 && "${near}" -le 120 ]]; then
    _t_pass "a 0.0009 degree step is ~100 m (got ${near} m)"
else
    _t_fail "a 0.0009 degree step should be ~100 m, got ${near} m"
fi

# --- _dec -------------------------------------------------------------------

# Zero-padded times must not be read as octal: "0830" as octal is invalid and
# would abort the comparison, stranding the daemon on the wrong app list.
_t_eq "830" "$(_dec 0830)" "_dec strips the leading zero from 0830"
_t_eq "500" "$(_dec 0500)" "_dec strips the leading zero from 0500"
_t_eq "0" "$(_dec 0000)" "_dec keeps a single digit for midnight"
_t_eq "2300" "$(_dec 2300)" "_dec leaves an unpadded time alone"
_t_eq "9" "$(_dec 0009)" "_dec strips several leading zeros"

# --- is_curfew_now, wrapping window (2300 -> 0500) --------------------------

_reset_dev
NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"

for t in 2300 2359 0000 0430; do
    _set_now "${t}"
    if is_curfew_now; then
        _t_pass "curfew is open at ${t} inside the wrapping window"
    else
        _t_fail "curfew should be open at ${t}"
    fi
done

for t in 0500 1200 2259; do
    _set_now "${t}"
    if ! is_curfew_now; then
        _t_pass "curfew is closed at ${t} outside the wrapping window"
    else
        _t_fail "curfew should be closed at ${t}"
    fi
done

# --- is_curfew_now, non-wrapping window -------------------------------------

NIGHT_CURFEW_START="0900"
NIGHT_CURFEW_END="1700"

_set_now "1200"
if is_curfew_now; then
    _t_pass "curfew is open midway through a same-day window"
else
    _t_fail "curfew should be open at 1200 for a 0900-1700 window"
fi

_set_now "0900"
if is_curfew_now; then
    _t_pass "a same-day window includes its start minute"
else
    _t_fail "0900 should be inside a 0900-1700 window"
fi

# The end is exclusive, or two adjacent windows would both claim the boundary.
_set_now "1700"
if ! is_curfew_now; then
    _t_pass "a same-day window excludes its end minute"
else
    _t_fail "1700 should be outside a 0900-1700 window"
fi

_set_now "0800"
if ! is_curfew_now; then
    _t_pass "curfew is closed before a same-day window opens"
else
    _t_fail "0800 should be outside a 0900-1700 window"
fi

NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"
# Read back so the reset has a reader in this file (SC2034); the subject is
# what actually consumes it, but each file is linted standalone.
_t_eq "2300-0500" "${NIGHT_CURFEW_START}-${NIGHT_CURFEW_END}" \
    "the wrapping window is restored for the remaining cases"

# A broken clock must fail OPEN — to the day list, not the strict one.
_set_now "not-a-time"
if ! is_curfew_now; then
    _t_pass "a malformed clock reads as no curfew rather than permanent curfew"
else
    _t_fail "a malformed clock must not enable the curfew"
fi

_set_now ""
if ! is_curfew_now; then
    _t_pass "an empty clock reading reads as no curfew"
else
    _t_fail "an empty clock must not enable the curfew"
fi

# --- curfew_active ----------------------------------------------------------

_reset_dev
_set_now "0000"
if curfew_active; then
    _t_pass "curfew is active inside the window when enabled"
else
    _t_fail "curfew should be active at 0000 when enabled"
fi

_reset_dev
_set_now "1200"
if ! curfew_active; then
    _t_pass "curfew is inactive outside the window"
else
    _t_fail "curfew should be inactive at 1200"
fi

# The force file is the test hook: it opens curfew regardless of the clock.
_reset_dev
_set_now "1200"
touch "${CURFEW_FORCE_FILE}"
if curfew_active; then
    _t_pass "the force file opens curfew outside the window"
else
    _t_fail "the force file should open curfew regardless of the clock"
fi

# The override must beat the force file, or there is no way out.
_reset_dev
touch "${CURFEW_OVERRIDE_FILE}"
_set_now "0000"
if ! curfew_active; then
    _t_pass "the override file closes curfew even when forced"
else
    _t_fail "the override must take precedence over the force file"
fi
rm -f "${CURFEW_OVERRIDE_FILE}" "${CURFEW_FORCE_FILE}"

_reset_dev
NIGHT_CURFEW_ENABLED=0
_set_now "0000"
if ! curfew_active; then
    _t_pass "curfew is inactive while the feature is disabled"
else
    _t_fail "curfew must be inactive when NIGHT_CURFEW_ENABLED is 0"
fi
NIGHT_CURFEW_ENABLED=1
_t_eq "1" "${NIGHT_CURFEW_ENABLED}" \
    "the curfew is re-enabled for the memo cases"

# The memo exists to stop is_curfew_now forking `date` once per package in
# the sweep. Proven by moving the clock and requiring the answer not to move.
_reset_dev
_set_now "0000"
curfew_active
_set_now "1200"
if curfew_active; then
    _t_pass "curfew_active answers from the per-tick memo, not the clock"
else
    _t_fail "the memo should hold within a tick even as the clock moves"
fi

# Clearing the memo is what main does each tick; the answer must then follow
# the clock again, or a curfew could never end.
_CURFEW_TICK_CACHED=""
if ! curfew_active; then
    _t_pass "clearing the memo lets the answer follow the clock again"
else
    _t_fail "a cleared memo must be recomputed"
fi
