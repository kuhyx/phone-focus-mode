#!/system/bin/sh
# shellcheck shell=ash
# ctl_hosts.sh — focus_ctl.sh's subcommands for the hosts-blocklist enforcer:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

HOSTS_PIDFILE="$STATE_DIR/hosts_enforcer.pid"

hosts_enforcer_pid() {
	if [ -f "$HOSTS_PIDFILE" ]; then
		local pid
		pid="$(cat "$HOSTS_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_hosts_status() {
	local pid
	pid="$(hosts_enforcer_pid)"
	echo "=== Hosts Enforcer Status ==="
	if [ -n "$pid" ]; then
		echo "Daemon:    RUNNING (PID $pid)"
	else
		echo "Daemon:    STOPPED"
	fi
	echo "Canonical: $HOSTS_CANONICAL"
	echo "Target:    $HOSTS_TARGET"
	if grep -qE "[[:space:]]${HOSTS_TARGET}[[:space:]]" /proc/self/mounts 2>/dev/null; then
		# A mount exists on the target path, but on Android the OEM sometimes
		# already mounts its own hosts file here. Trust the sha check below.
		echo "Mount:     present (integrity check below tells us if ours)"
	else
		echo "Mount:     NOT mounted (unprotected)"
	fi
	if [ -f "$HOSTS_CANONICAL" ]; then
		local expected actual
		expected="$(cat "$HOSTS_SHA_FILE" 2>/dev/null)"
		if command -v sha256sum >/dev/null 2>&1; then
			actual="$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{print $1}')"
		else
			actual="$(md5sum "$HOSTS_TARGET" 2>/dev/null | awk '{print $1}')"
		fi
		echo "Expected:  ${expected:-<none>}"
		echo "Actual:    ${actual:-<unreadable>}"
		if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
			echo "Integrity: OK"
		else
			echo "Integrity: MISMATCH"
		fi
	else
		echo "Canonical hosts file missing - run deploy.sh"
	fi
	# Magisk Systemless Hosts module protection state.
	local module_dir="/data/adb/modules/hosts"
	if [ -d "$module_dir" ]; then
		local lock_state="UNLOCKED (Magisk app can disable!)"
		if lsattr -d "$module_dir" 2>/dev/null | awk '{print $1}' | grep -q i; then
			lock_state="LOCKED (chattr +i)"
		fi
		echo "Magisk dir: $module_dir [$lock_state]"
		local marker_warn=""
		for marker in disable remove update; do
			if [ -e "$module_dir/$marker" ]; then
				marker_warn="$marker_warn $marker"
			fi
		done
		if [ -n "$marker_warn" ]; then
			echo "WARN:      Magisk markers present:$marker_warn (will be auto-removed by hosts_enforcer)"
		fi
	else
		echo "Magisk dir: <missing - module not installed>"
	fi
}

cmd_hosts_start() {
	local pid
	pid="$(hosts_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Hosts enforcer already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/hosts_enforcer.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(hosts_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Hosts enforcer started (PID $pid)"
	else
		echo "ERROR: hosts enforcer failed to start. Check log: $HOSTS_LOG"
	fi
}

cmd_hosts_stop() {
	local pid
	pid="$(hosts_enforcer_pid)"
	if [ -z "$pid" ]; then
		echo "Hosts enforcer not running"
		rm -f "$HOSTS_PIDFILE"
		return
	fi
	kill -TERM "$pid"
	echo "Hosts enforcer stopped (sent SIGTERM to PID $pid)"
}

cmd_hosts_log() {
	local lines="${1:-50}"
	if [ -f "$HOSTS_LOG" ]; then
		tail -n "$lines" "$HOSTS_LOG"
	else
		echo "Hosts enforcer log not found: $HOSTS_LOG"
	fi
}
