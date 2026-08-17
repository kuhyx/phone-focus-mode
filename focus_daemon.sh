#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Focus Mode Daemon
# Runs on rooted Android device. Periodically checks GPS
# location and restricts non-whitelisted apps when near home.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
# shellcheck source=daemon_location.sh
. "$SCRIPT_DIR/daemon_location.sh"
# shellcheck source=daemon_state.sh
. "$SCRIPT_DIR/daemon_state.sh"
# shellcheck source=daemon_apps.sh
. "$SCRIPT_DIR/daemon_apps.sh"

PIDFILE="$STATE_DIR/daemon.pid"

# ---- PID lock: exit if already running ----
acquire_lock() {
	mkdir -p "$STATE_DIR"
	if [ -f "$PIDFILE" ]; then
		local old_pid
		old_pid="$(cat "$PIDFILE")"
		if kill -0 "$old_pid" 2>/dev/null; then
			# Verify the PID is actually a focus_daemon, not a reused PID
			local cmdline
			cmdline="$(tr '\0' ' ' <"/proc/$old_pid/cmdline" 2>/dev/null)"
			if echo "$cmdline" | grep -q "focus_daemon"; then
				echo "Daemon already running (PID $old_pid), exiting."
				exit 0
			fi
		fi
		# Stale or reused pidfile
		rm -f "$PIDFILE"
	fi
	echo $$ >"$PIDFILE"
}

# ---- Logging ----
log() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$ts] $1" >>"$LOG_FILE"
}

rotate_log() {
	local lines
	lines="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
	if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
		local tmp="$LOG_FILE.tmp"
		tail -n "$LOG_MAX_LINES" "$LOG_FILE" >"$tmp"
		mv "$tmp" "$LOG_FILE"
	fi
}

# ---- Build helper files for fast package checks ----






# ---- Initialization ----
init() {
	mkdir -p "$STATE_DIR"
	touch "$LOG_FILE"
	touch "$DISABLED_APPS_FILE"
	# Ensure state files are writable (survives reboot / permission drift)
	chmod 666 "$LOG_FILE" "$DISABLED_APPS_FILE" "$PIDFILE" 2>/dev/null
	# Status file must be world-readable (companion app reads it).
	# State dir must be world-writable+executable so the companion app can
	# drop the recheck trigger file (it runs as a normal app UID).
	chmod 777 "$STATE_DIR" 2>/dev/null

	if [ "$HOME_LAT" = "0.000000" ] && [ "$HOME_LON" = "0.000000" ]; then
		log "ERROR: Home coordinates not set! Edit config_secrets.sh first."
		exit 1
	fi

	if ! echo "$HOME_LAT" | grep -Eq '^[-]?[0-9]+(\.[0-9]+)?$'; then
		log "ERROR: HOME_LAT is invalid ('$HOME_LAT'). Expected decimal degrees in config_secrets.sh"
		exit 1
	fi

	if ! echo "$HOME_LON" | grep -Eq '^[-]?[0-9]+(\.[0-9]+)?$'; then
		log "ERROR: HOME_LON is invalid ('$HOME_LON'). Expected decimal degrees in config_secrets.sh"
		exit 1
	fi

	build_whitelist_file
	build_night_whitelist_file
	build_sysprotect_file
	build_blocked_sys_file
	refresh_default_handlers
	rotate_log

	if [ -f "$MODE_FILE" ]; then
		CURRENT_MODE="$(cat "$MODE_FILE")"
	else
		CURRENT_MODE="normal"
	fi

	if [ "$CURRENT_MODE" = "focus" ]; then
		reconcile_disabled_apps
	fi

	log "Focus mode daemon started (PID=$$, mode=$CURRENT_MODE, home=$HOME_LAT,$HOME_LON, radius=${RADIUS}m)"
	log "Intervals: focus=${CHECK_INTERVAL_FOCUS}s normal=${CHECK_INTERVAL_NORMAL}s"
}









# ---- Focus Mode Control ----




# ---- Sleep with early-wake on recheck trigger ----
# Polls for $RECHECK_TRIGGER every second; if found, consumes it and returns
# early. The file can be touched by the companion app (via "Re-check now"
# button) or by `focus_ctl.sh recheck` from a shell.
sleep_with_recheck() {
	local total="$1"
	local elapsed=0
	while [ "$elapsed" -lt "$total" ]; do
		if [ -e "$RECHECK_TRIGGER" ]; then
			rm -f "$RECHECK_TRIGGER" 2>/dev/null
			log "Manual re-check triggered"
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
}

# ---- Signal handlers ----
cleanup() {
	log "Daemon shutting down - re-enabling all apps"
	disable_focus_mode
	rm -f "$PIDFILE"
	exit 0
}

# HUP is intentionally NOT trapped so the daemon survives ADB disconnects.
# Only SIGTERM/SIGINT trigger a clean shutdown.
trap cleanup INT TERM

# ---- Main Loop ----
main() {
	acquire_lock
	init

	while true; do
		# Invalidate the per-tick curfew_active() memo (see its definition).
		_CURFEW_TICK_CACHED=""

		location="$(get_location)"

		if [ -n "$location" ]; then
			lat="$(echo "$location" | cut -d',' -f1)"
			lon="$(echo "$location" | cut -d',' -f2)"
			distance="$(calc_distance "$lat" "$lon" "$HOME_LAT" "$HOME_LON")"

			if [ "$CURRENT_MODE" = "focus" ]; then
				threshold=$((RADIUS + HYSTERESIS))
			else
				threshold=$((RADIUS - HYSTERESIS))
			fi

			if [ "$distance" -le "$threshold" ] 2>/dev/null; then
				enable_focus_mode
			else
				disable_focus_mode
			fi

			curfew_state="day"
			curfew_active && curfew_state="CURFEW"
			log "Location: $lat,$lon | Distance: ${distance}m | Threshold: ${threshold}m | Mode: $CURRENT_MODE | Curfew: $curfew_state"
			write_status_snapshot "$CURRENT_MODE" "$lat" "$lon" "$distance" "$threshold"
		else
			log "Location unavailable - defaulting to focus mode (restrictions ON)"
			enable_focus_mode
			write_status_snapshot "$CURRENT_MODE" "" "" "null" "null"
		fi

		# Dynamic interval: shorter at home (can charge), longer away (save battery).
		# sleep_with_recheck returns early if the companion app requests a recheck.
		if [ "$CURRENT_MODE" = "focus" ]; then
			sleep_with_recheck "$CHECK_INTERVAL_FOCUS"
		else
			sleep_with_recheck "$CHECK_INTERVAL_NORMAL"
		fi

		rotate_log
	done
}

main "$@"
