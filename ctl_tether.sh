#!/system/bin/sh
# shellcheck shell=ash
# ctl_tether.sh — focus_ctl.sh's subcommands for the tethering enforcer:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

TETHER_PIDFILE="$STATE_DIR/tether_enforcer.pid"

tether_enforcer_pid() {
	if [ -f "$TETHER_PIDFILE" ]; then
		local pid
		pid="$(cat "$TETHER_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_tether_status() {
	local pid
	pid="$(tether_enforcer_pid)"
	echo "=== Hotspot / Tethering Block Status ==="
	echo "Enabled:        ${TETHER_ENFORCER_ENABLED}"
	if [ -n "$pid" ]; then
		echo "Enforcer:       RUNNING (PID $pid)"
	else
		echo "Enforcer:       STOPPED"
	fi
	if [ -f "$MODE_FILE" ]; then
		echo "Focus mode:     $(cat "$MODE_FILE" 2>/dev/null)"
	fi
	[ -e "$TETHER_FORCE_FILE" ] && echo "Forced ON:      YES (test active)"
	[ -e "$TETHER_OVERRIDE_FILE" ] && echo "Override:       YES (block SUSPENDED)"
	[ -e "$TETHER_ENFORCER_STATE" ] && echo "Applied now:    YES (offload off + FORWARD reject)" ||
		echo "Applied now:    no"
	local off
	off="$(settings get global "$TETHER_OFFLOAD_KEY" 2>/dev/null)"
	echo "tether_offload_disabled: ${off:-<unset>}"
	if iptables -C FORWARD -j "$TETHER_IPT_CHAIN" >/dev/null 2>&1; then
		echo "iptables $TETHER_IPT_CHAIN: pinned to FORWARD ($(iptables -S "$TETHER_IPT_CHAIN" 2>/dev/null | grep -c '^-A') rule)"
	else
		echo "iptables $TETHER_IPT_CHAIN: absent (block not applied)"
	fi
}

cmd_tether_start() {
	local pid
	pid="$(tether_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Tether enforcer already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/tether_enforcer.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(tether_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Tether enforcer started (PID $pid)"
	else
		echo "ERROR: tether enforcer failed to start. Check log: $TETHER_LOG"
	fi
}

cmd_tether_stop() {
	local pid
	pid="$(tether_enforcer_pid)"
	if [ -z "$pid" ]; then
		echo "Tether enforcer not running"
		rm -f "$TETHER_PIDFILE"
	else
		kill -TERM "$pid"
		echo "Tether enforcer stopped (sent SIGTERM to PID $pid)"
	fi
	# Explicit teardown so maintenance can tether even if the daemon was already
	# dead (its own TERM handler reverts too; this is the belt-and-suspenders).
	iptables -D FORWARD -j "$TETHER_IPT_CHAIN" 2>/dev/null || true
	iptables -F "$TETHER_IPT_CHAIN" 2>/dev/null || true
	iptables -X "$TETHER_IPT_CHAIN" 2>/dev/null || true
	ip6tables -D FORWARD -j "$TETHER_IPT_CHAIN" 2>/dev/null || true
	ip6tables -F "$TETHER_IPT_CHAIN" 2>/dev/null || true
	ip6tables -X "$TETHER_IPT_CHAIN" 2>/dev/null || true
	echo "FORWARD chain $TETHER_IPT_CHAIN removed (tethering restored)"
}

cmd_tether_log() { tail -n "${1:-50}" "$TETHER_LOG" 2>/dev/null || echo "No tether log yet."; }

# Test hook: force the block ACTIVE regardless of location so the full stack can
# be validated during the day with a real second phone on the hotspot.
cmd_tether_test_on() {
	touch "$TETHER_FORCE_FILE"
	chmod 666 "$TETHER_FORCE_FILE" 2>/dev/null || true
	rm -f "$TETHER_OVERRIDE_FILE"
	echo "Tether block FORCED ON. Enforcer engages within ${TETHER_CHECK_INTERVAL}s."
	echo "Validate: second phone on the hotspot loses internet; this phone stays online."
}

cmd_tether_test_off() {
	rm -f "$TETHER_FORCE_FILE"
	echo "Tether force cleared. Back to focus-mode-gated behaviour."
}
