#!/system/bin/sh
# shellcheck shell=ash
# ctl_daemon.sh — focus_ctl.sh's subcommands for the main focus daemon:
# start, stop, status, enable, disable, recheck, log and the companion
# notification status.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory.
# Sourced by focus_ctl.sh, which owns log() and the config.sh globals these
# read. $PIDFILE lives here rather than in the entry script because this file
# is its only reader (SC2034), and the linter runs without -x so each file
# stands alone.

PIDFILE="$STATE_DIR/daemon.pid"

# Helper to check if daemon is running
daemon_pid() {
	if [ -f "$PIDFILE" ]; then
		local pid
		pid="$(cat "$PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_start() {
	local pid
	pid="$(daemon_pid)"
	if [ -n "$pid" ]; then
		echo "Daemon already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/focus_daemon.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(daemon_pid)"
	if [ -n "$pid" ]; then
		echo "Daemon started (PID $pid)"
	else
		echo "ERROR: Daemon failed to start. Check log: $LOG_FILE"
	fi
}

cmd_stop() {
	local pid
	pid="$(daemon_pid)"
	if [ -z "$pid" ]; then
		echo "Daemon not running"
		# Clean up stale pidfile if present
		rm -f "$PIDFILE"
	else
		kill -TERM "$pid"
		echo "Daemon stopped (sent SIGTERM to PID $pid)"
	fi
}

cmd_status() {
	local pid
	pid="$(daemon_pid)"
	local mode="unknown"
	[ -f "$MODE_FILE" ] && mode="$(cat "$MODE_FILE")"

	echo "=== Focus Mode Status ==="
	if [ -n "$pid" ]; then
		echo "Daemon:   RUNNING (PID $pid)"
	else
		echo "Daemon:   STOPPED"
	fi
	echo "Mode:     $mode"
	echo "Home:     $HOME_LAT, $HOME_LON (radius: ${RADIUS}m)"
	echo ""

	# Show current location if available
	location="$(dumpsys location 2>/dev/null |
		grep -oE 'Location\[.*[-]?[0-9]{1,3}\.[0-9]+,[-]?[0-9]{1,3}\.[0-9]+' |
		grep -oE '[-]?[0-9]{1,3}\.[0-9]+,[-]?[0-9]{1,3}\.[0-9]+' |
		head -1)"

	if [ -n "$location" ]; then
		lat="$(echo "$location" | cut -d',' -f1)"
		lon="$(echo "$location" | cut -d',' -f2)"
		dist="$(echo "$lat $lon $HOME_LAT $HOME_LON" | awk '{
            PI=3.14159265358979; R=6371000
            a1=$1*PI/180; o1=$2*PI/180
            a2=$3*PI/180; o2=$4*PI/180
            da=a2-a1; dlon=o2-o1
            x=sin(da/2)^2+cos(a1)*cos(a2)*sin(dlon/2)^2
            printf "%d", R*2*atan2(sqrt(x),sqrt(1-x))
        }')"
		echo "Location: $lat, $lon"
		echo "Distance: ${dist}m from home"
	else
		echo "Location: unavailable"
	fi

	echo ""
	if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
		echo "=== Apps disabled by focus mode ==="
		cat "$DISABLED_APPS_FILE"
	else
		echo "No apps currently disabled by focus mode"
	fi
}

cmd_enable() {
	# Disable daemon temporarily, force focus
	echo "Forcing focus mode ON..."
	. "$SCRIPT_DIR/config.sh"

	# Source common functions - inline here for standalone use
	: >"$STATE_DIR/disabled_by_focus.txt"
	local count=0
	for pkg in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
		# Check whitelist
		whitelisted=0
		for w in $(iter_whitelist_packages); do
			w_clean="$(echo "$w" | tr -d '[:space:]')"
			[ -z "$w_clean" ] && continue
			[ "$pkg" = "$w_clean" ] && {
				whitelisted=1
				break
			}
		done
		[ "$whitelisted" -eq 1 ] && continue

		# Check system protection
		protected=0
		for prefix in $SYSTEM_NEVER_DISABLE; do
			prefix_clean="$(echo "$prefix" | tr -d '[:space:]')"
			[ -z "$prefix_clean" ] && continue
			case "$pkg" in
			"$prefix_clean"*)
				protected=1
				break
				;;
			esac
		done
		[ "$protected" -eq 1 ] && continue

		if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
			echo "$pkg" >>"$STATE_DIR/disabled_by_focus.txt"
			count=$((count + 1))
		fi
	done
	echo "focus" >"$MODE_FILE"
	echo "Done: disabled $count apps"
}

cmd_recheck() {
	# Write the trigger file; the daemon's sleep_with_recheck() will pick it
	# up within ~1 second and perform an immediate location check.
	if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
		echo "Daemon not running - start it first with: focus_ctl.sh start"
		return 1
	fi
	touch "$RECHECK_TRIGGER"
	chmod 666 "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Recheck requested. Tail the log to see the next reading:"
	echo "  tail -f $LOG_FILE"
}

cmd_notif_status() {
	if [ -f "$STATUS_FILE" ]; then
		echo "=== $STATUS_FILE ==="
		cat "$STATUS_FILE"
		echo
	else
		echo "No status snapshot yet (daemon has not written $STATUS_FILE)."
	fi
	if command -v dumpsys >/dev/null 2>&1; then
		echo "=== Companion app state ==="
		dumpsys package com.kuhy.focusstatus 2>/dev/null | grep -E 'enabled=|installed=|userId=' | head -5 || true
	fi
}

cmd_disable() {
	echo "Forcing focus mode OFF..."
	if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
		local count=0
		while IFS= read -r pkg; do
			[ -z "$pkg" ] && continue
			pm enable "$pkg" >/dev/null 2>&1 && count=$((count + 1))
		done <"$DISABLED_APPS_FILE"
		: >"$DISABLED_APPS_FILE"
		echo "Done: re-enabled $count apps"
	else
		echo "No apps to re-enable"
	fi
	echo "normal" >"$MODE_FILE"
}

cmd_log() {
	local lines="${1:-50}"
	if [ -f "$LOG_FILE" ]; then
		tail -n "$lines" "$LOG_FILE"
	else
		echo "Log file not found: $LOG_FILE"
	fi
}
