#!/system/bin/sh
# shellcheck shell=ash
# ctl_launcher.sh — focus_ctl.sh's subcommands for the minimalist-launcher enforcer:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

LAUNCHER_PIDFILE="$STATE_DIR/launcher_enforcer.pid"
DISABLED_COMPETITORS_FILE="$STATE_DIR/disabled_competitors.txt"

launcher_enforcer_pid() {
	if [ -f "$LAUNCHER_PIDFILE" ]; then
		local pid
		pid="$(cat "$LAUNCHER_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_launcher_snapshot() {
	# Find the APK path for the currently-installed launcher and copy it
	# to LAUNCHER_APK. Also capture the current HOME activity component.
	local apk_path
	apk_path="$(pm path "$LAUNCHER_PACKAGE" 2>/dev/null | head -1 | sed 's/^package://')"
	if [ -z "$apk_path" ] || [ ! -f "$apk_path" ]; then
		echo "ERROR: $LAUNCHER_PACKAGE is not installed. Install it once via Aurora/Play Store, then rerun this command."
		return 1
	fi
	mkdir -p "$(dirname "$LAUNCHER_APK")"
	chattr -i "$LAUNCHER_APK" "$LAUNCHER_SHA_FILE" "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null || true
	cp "$apk_path" "$LAUNCHER_APK" || return 1
	chmod 644 "$LAUNCHER_APK"
	sha256sum "$LAUNCHER_APK" | awk '{print $1}' >"$LAUNCHER_SHA_FILE"
	chmod 644 "$LAUNCHER_SHA_FILE"

	# Resolve the current HOME activity (or the launcher's default activity
	# if it isn't yet the default).
	local component
	component="$(cmd package resolve-activity --brief \
		-c android.intent.category.HOME \
		-a android.intent.action.MAIN 2>/dev/null | awk 'NR==2{print}')"
	if [ -z "$component" ] || [ "${component%%/*}" != "$LAUNCHER_PACKAGE" ]; then
		# Fall back to the launcher's MAIN/LAUNCHER activity
		component="$(cmd package resolve-activity --brief \
			-c android.intent.category.LAUNCHER \
			-a android.intent.action.MAIN "$LAUNCHER_PACKAGE" 2>/dev/null |
			awk 'NR==2{print}')"
	fi
	if [ -z "$component" ]; then
		echo "ERROR: could not resolve HOME activity for $LAUNCHER_PACKAGE"
		return 1
	fi
	echo "$component" >"$LAUNCHER_ACTIVITY_FILE"
	chmod 644 "$LAUNCHER_ACTIVITY_FILE"

	# Make snapshot immutable so even root-in-a-terminal can't overwrite
	# it without first running `chattr -i`.
	chattr +i "$LAUNCHER_APK" "$LAUNCHER_SHA_FILE" "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null || true

	echo "Snapshot saved:"
	echo "  APK:      $LAUNCHER_APK ($(wc -c <"$LAUNCHER_APK") bytes)"
	echo "  SHA256:   $(cat "$LAUNCHER_SHA_FILE")"
	echo "  Activity: $component"
}

cmd_launcher_status() {
	local pid
	pid="$(launcher_enforcer_pid)"
	echo "=== Launcher Enforcer Status ==="
	if [ -n "$pid" ]; then
		echo "Daemon:     RUNNING (PID $pid)"
	else
		echo "Daemon:     STOPPED"
	fi
	echo "Package:    $LAUNCHER_PACKAGE"
	if pm path "$LAUNCHER_PACKAGE" >/dev/null 2>&1; then
		echo "Installed:  YES ($(pm path "$LAUNCHER_PACKAGE" | head -1))"
	else
		echo "Installed:  NO"
	fi
	local desired actual
	desired="$(cat "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null)"
	actual="$(cmd package resolve-activity --brief \
		-c android.intent.category.HOME -a android.intent.action.MAIN \
		2>/dev/null | awk 'NR==2{print}')"
	echo "Expected:   ${desired:-<not armed - run launcher-snapshot>}"
	echo "Actual:     ${actual:-<unresolved>}"
	if [ -n "$desired" ] && [ "$desired" = "$actual" ]; then
		echo "Default:    OK (pinned)"
	else
		echo "Default:    MISMATCH"
	fi
	echo "Snapshot:   $LAUNCHER_APK"
	if [ -f "$LAUNCHER_APK" ]; then
		echo "Snapshot size: $(wc -c <"$LAUNCHER_APK") bytes"
	fi
	if [ -s "$DISABLED_COMPETITORS_FILE" ]; then
		echo "Disabled competitors:"
		sed 's/^/  - /' "$DISABLED_COMPETITORS_FILE"
	fi
}

cmd_launcher_start() {
	local pid
	pid="$(launcher_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Launcher enforcer already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/launcher_enforcer.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(launcher_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Launcher enforcer started (PID $pid)"
	else
		echo "ERROR: launcher enforcer failed to start. Check log: $LAUNCHER_LOG"
	fi
}

cmd_launcher_stop() {
	local pid
	pid="$(launcher_enforcer_pid)"
	if [ -z "$pid" ]; then
		echo "Launcher enforcer not running"
		rm -f "$LAUNCHER_PIDFILE"
	else
		kill -TERM "$pid"
		echo "Launcher enforcer stopped (sent SIGTERM to PID $pid)"
	fi
	# Re-enable any competitors we disabled so the device is usable if the
	# enforcer is intentionally stopped (e.g. during maintenance).
	if [ -s "$DISABLED_COMPETITORS_FILE" ]; then
		while read -r pkg; do
			[ -z "$pkg" ] && continue
			pm enable --user 0 "$pkg" >/dev/null 2>&1 &&
				echo "Re-enabled competing launcher: $pkg"
		done <"$DISABLED_COMPETITORS_FILE"
		: >"$DISABLED_COMPETITORS_FILE"
	fi
}

cmd_launcher_log() {
	local lines="${1:-50}"
	if [ -f "$LAUNCHER_LOG" ]; then
		tail -n "$lines" "$LAUNCHER_LOG"
	else
		echo "Launcher enforcer log not found: $LAUNCHER_LOG"
	fi
}
