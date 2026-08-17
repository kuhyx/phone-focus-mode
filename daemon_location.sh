#!/system/bin/sh
# shellcheck shell=ash
# daemon_location.sh — where-and-when for focus_daemon.sh: reading the phone's
# GPS fix, the great-circle distance from home, and whether the night curfew
# window is currently open.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory.
#
# Sourced by focus_daemon.sh, which owns log() and the config.sh globals these
# read ($NIGHT_CURFEW_*, $CURFEW_FORCE_FILE, $CURFEW_OVERRIDE_FILE). It also
# owns $_CURFEW_TICK_CACHED: curfew_active memoises per tick and main clears
# the memo each loop, so both files write it and it stays with main.

# ---- Location ----
get_location() {
	dumpsys location 2>/dev/null |
		grep -oE '[-]?[0-9]{1,3}\.[0-9]{4,},[-]?[0-9]{1,3}\.[0-9]{4,}' |
		head -1
}

# ---- Distance Calculation (Haversine via awk) ----
calc_distance() {
	echo "$1 $2 $3 $4" | awk '{
        PI = 3.14159265358979323846
        R = 6371000.0
        lat1 = $1 * PI / 180.0
        lon1 = $2 * PI / 180.0
        lat2 = $3 * PI / 180.0
        lon2 = $4 * PI / 180.0
        dlat = lat2 - lat1
        dlon = lon2 - lon1
        sdlat = sin(dlat / 2.0)
        sdlon = sin(dlon / 2.0)
        a = sdlat * sdlat + cos(lat1) * cos(lat2) * sdlon * sdlon
        c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        printf "%d\n", R * c
    }'
}

# ---- Night curfew time check ----
# Returns 0 (true) when the local clock is inside the curfew window.
# Fails OPEN (return 1 = not curfew) on a malformed clock so a broken `date`
# can never strand you behind the strict list — essentials stay reachable
# either way, but the day list is the less-surprising default.
_dec() {
	# Strip leading zeros so a zero-padded HHMM ("0500", "0830") is not parsed
	# as (sometimes invalid) octal by the shell's arithmetic. Portable across
	# ash/mksh; keeps at least one digit so "0000" -> "0".
	local n="$1"
	while [ "${n#0}" != "$n" ] && [ "${#n}" -gt 1 ]; do n="${n#0}"; done
	printf '%s' "$n"
}

is_curfew_now() {
	local now start end
	now="$(date +%H%M 2>/dev/null)"
	case "$now" in
	'' | *[!0-9]*) return 1 ;;
	esac
	now="$(_dec "$now")"
	start="$(_dec "$NIGHT_CURFEW_START")"
	end="$(_dec "$NIGHT_CURFEW_END")"
	if [ "$start" -le "$end" ]; then
		[ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
	else
		# Window wraps past midnight (e.g. 2300 -> 0500).
		[ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
	fi
}

# Curfew is ACTIVE when enabled, not manually overridden, and either forced on
# (test hook) or inside the time window. The is_allowed() switch below consults
# this; because is_allowed() only runs during the focus-mode sweep/reconcile,
# curfew automatically takes effect only at home and is a no-op when away.
#
# Memoized once per main-loop tick (reset at the top of main()'s while loop):
# is_allowed() calls this once per enabled package in the sweep, and
# is_curfew_now forks `date` - on-device this meant up to ~N extra forks per
# 10s tick for N enabled apps, all recomputing a value that cannot change
# within a single tick. Result is cached in _CURFEW_TICK_RESULT.
curfew_active() {
	if [ -n "$_CURFEW_TICK_CACHED" ]; then
		[ "$_CURFEW_TICK_RESULT" = "1" ]
		return
	fi
	_CURFEW_TICK_CACHED=1
	_CURFEW_TICK_RESULT=0
	if [ "${NIGHT_CURFEW_ENABLED:-0}" = "1" ] && [ ! -e "$CURFEW_OVERRIDE_FILE" ]; then
		if [ -e "$CURFEW_FORCE_FILE" ] || is_curfew_now; then
			_CURFEW_TICK_RESULT=1
		fi
	fi
	[ "$_CURFEW_TICK_RESULT" = "1" ]
}
