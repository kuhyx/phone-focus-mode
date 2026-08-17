#!/system/bin/sh
# shellcheck shell=ash
# ctl_workout.sh — focus_ctl.sh's subcommands for the workout detector:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

WORKOUT_PIDFILE="$STATE_DIR/workout_detector.pid"

workout_detector_pid() {
	if [ -f "$WORKOUT_PIDFILE" ]; then
		local pid
		pid="$(cat "$WORKOUT_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_workout_status() {
	local pid
	pid="$(workout_detector_pid)"
	echo "=== Workout Detector Status ==="
	if [ -n "$pid" ]; then
		echo "Daemon:        RUNNING (PID $pid)"
	else
		echo "Daemon:        STOPPED"
	fi
	echo "Package:       $WORKOUT_TRIGGER_PACKAGE"
	if pm path "$WORKOUT_TRIGGER_PACKAGE" >/dev/null 2>&1; then
		echo "Installed:     YES"
	else
		echo "Installed:     NO (detector will always report inactive)"
	fi
	echo "sqlite3:       $WORKOUT_SQLITE3_BIN"
	if [ -x "$WORKOUT_SQLITE3_BIN" ]; then
		echo "sqlite3 ver:   $("$WORKOUT_SQLITE3_BIN" -version 2>/dev/null | awk '{print $1}')"
	else
		echo "sqlite3 ver:   <missing or not executable — detector cannot query DB>"
	fi
	echo "DB path:       $WORKOUT_DB_PATH"
	if [ -f "$WORKOUT_DB_PATH" ]; then
		echo "DB present:    YES"
	else
		echo "DB present:    NO"
	fi
	echo "Poll interval: ${WORKOUT_DETECTOR_INTERVAL}s"
	local flag="<unset>"
	if [ -f "$WORKOUT_ACTIVE_FILE" ]; then
		flag="$(cat "$WORKOUT_ACTIVE_FILE" 2>/dev/null)"
	fi
	case "$flag" in
	1) echo "Workout flag:  1 (workout IN PROGRESS → YouTube hosts UNBLOCKED)" ;;
	0) echo "Workout flag:  0 (no workout → YouTube hosts BLOCKED)" ;;
	*) echo "Workout flag:  '$flag' (treated as 0, fail-closed)" ;;
	esac
	# Live one-shot query so the user can see ground truth without waiting
	# for the next poll cycle. Best-effort — never fails the status command.
	if [ -x "$WORKOUT_SQLITE3_BIN" ] && [ -f "$WORKOUT_DB_PATH" ]; then
		local live_count
		live_count="$("$WORKOUT_SQLITE3_BIN" "file:${WORKOUT_DB_PATH}?mode=ro" \
			"SELECT COUNT(*) FROM workouts WHERE start>0 AND (finish IS NULL OR finish=0);" \
			2>/dev/null)"
		echo "Live DB query: in-progress workouts = ${live_count:-<query failed>}"
	fi
	if [ -f "$HOSTS_CANONICAL_WORKOUT" ]; then
		echo "Workout hosts: $HOSTS_CANONICAL_WORKOUT ($(wc -l <"$HOSTS_CANONICAL_WORKOUT" 2>/dev/null) lines)"
	else
		echo "Workout hosts: <missing — deploy.sh must regenerate it>"
	fi
}

cmd_workout_start() {
	local pid
	pid="$(workout_detector_pid)"
	if [ -n "$pid" ]; then
		echo "Workout detector already running (PID $pid)"
		return
	fi
	if [ ! -x "$WORKOUT_SQLITE3_BIN" ]; then
		echo "ERROR: $WORKOUT_SQLITE3_BIN missing or not executable. Re-run deploy.sh."
		return 1
	fi
	setsid sh "$SCRIPT_DIR/workout_detector.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(workout_detector_pid)"
	if [ -n "$pid" ]; then
		echo "Workout detector started (PID $pid)"
	else
		echo "ERROR: Workout detector failed to start. Check log: $WORKOUT_DETECTOR_LOG"
	fi
}

cmd_workout_stop() {
	local pid
	pid="$(workout_detector_pid)"
	if [ -z "$pid" ]; then
		echo "Workout detector not running"
		rm -f "$WORKOUT_PIDFILE"
	else
		kill -TERM "$pid"
		echo "Workout detector stopped (sent SIGTERM to PID $pid)"
	fi
	# Fail-closed on manual stop: write 0 so the hosts enforcer reverts to
	# the full-block canonical and YouTube goes back to being blocked.
	printf '0\n' >"$WORKOUT_ACTIVE_FILE" 2>/dev/null || true
	chmod 666 "$WORKOUT_ACTIVE_FILE" 2>/dev/null || true
	echo "workout_active flag forced to 0"
}

cmd_workout_log() {
	local lines="${1:-50}"
	if [ -f "$WORKOUT_DETECTOR_LOG" ]; then
		tail -n "$lines" "$WORKOUT_DETECTOR_LOG"
	else
		echo "Workout detector log not found: $WORKOUT_DETECTOR_LOG"
	fi
}
