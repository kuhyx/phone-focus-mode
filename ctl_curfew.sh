#!/system/bin/sh
# shellcheck shell=ash
# ctl_curfew.sh — focus_ctl.sh's subcommands for the night-curfew enforcer:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

CURFEW_PIDFILE="$STATE_DIR/curfew_enforcer.pid"

curfew_enforcer_pid() {
	if [ -f "$CURFEW_PIDFILE" ]; then
		local pid
		pid="$(cat "$CURFEW_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

# Replicates focus_daemon.sh::is_curfew_now for status display.
_ctl_dec() {
	local n="$1"
	while [ "${n#0}" != "$n" ] && [ "${#n}" -gt 1 ]; do n="${n#0}"; done
	printf '%s' "$n"
}

ctl_is_curfew_now() {
	local now start end
	now="$(date +%H%M 2>/dev/null)"
	case "$now" in '' | *[!0-9]*) return 1 ;; esac
	now="$(_ctl_dec "$now")"
	start="$(_ctl_dec "$NIGHT_CURFEW_START")"
	end="$(_ctl_dec "$NIGHT_CURFEW_END")"
	if [ "$start" -le "$end" ]; then
		[ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
	else
		[ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
	fi
}

cmd_curfew_status() {
	local pid
	pid="$(curfew_enforcer_pid)"
	echo "=== Night Curfew Status ==="
	echo "Enabled:        ${NIGHT_CURFEW_ENABLED}"
	echo "Window:         ${NIGHT_CURFEW_START}-${NIGHT_CURFEW_END} (now $(date +%H%M))"
	if [ -n "$pid" ]; then
		echo "Enforcer:       RUNNING (PID $pid)"
	else
		echo "Enforcer:       STOPPED"
	fi
	ctl_is_curfew_now && echo "Within window:  YES" || echo "Within window:  no"
	[ -e "$CURFEW_FORCE_FILE" ] && echo "Forced ON:      YES (demo/test active)"
	[ -e "$CURFEW_OVERRIDE_FILE" ] && echo "Override:       YES (curfew SUSPENDED)"
	if [ -f "$MODE_FILE" ]; then
		echo "Focus mode:     $(cat "$MODE_FILE" 2>/dev/null)"
	fi
	[ -e "$CURFEW_ENFORCER_STATE" ] && echo "Applied now:    YES (grayscale/DND locked)" ||
		echo "Applied now:    no"
	echo "Grayscale:      ${CURFEW_GRAYSCALE_ENABLED}   DND: ${CURFEW_DND_ENABLED}   Net: ${CURFEW_NET_ENABLED}"
	if iptables -L "$CURFEW_NET_IPT_CHAIN" >/dev/null 2>&1; then
		echo "iptables $CURFEW_NET_IPT_CHAIN: $(iptables -S "$CURFEW_NET_IPT_CHAIN" 2>/dev/null | wc -l) rules"
	else
		echo "iptables $CURFEW_NET_IPT_CHAIN: absent (net curfew not applied)"
	fi
	if [ -f "$STATE_DIR/night_whitelist.txt" ]; then
		echo "Night whitelist: $(wc -l <"$STATE_DIR/night_whitelist.txt" | tr -d ' ') apps allowed"
	fi
}

cmd_curfew_start() {
	local pid
	pid="$(curfew_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Curfew enforcer already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/curfew_enforcer.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(curfew_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "Curfew enforcer started (PID $pid)"
	else
		echo "ERROR: curfew enforcer failed to start. Check log: $CURFEW_ENFORCER_LOG"
	fi
}

cmd_curfew_stop() {
	local pid
	pid="$(curfew_enforcer_pid)"
	if [ -n "$pid" ]; then
		kill "$pid" 2>/dev/null
		echo "Curfew enforcer stopped (PID $pid) - daytime state restored"
	else
		echo "Curfew enforcer not running"
	fi
}

# Test hook: force curfew ACTIVE regardless of clock/location so the whole
# stack can be validated during the day. Daemon re-checks within one tick.
cmd_curfew_test_on() {
	touch "$CURFEW_FORCE_FILE"
	chmod 666 "$CURFEW_FORCE_FILE" 2>/dev/null || true
	rm -f "$CURFEW_OVERRIDE_FILE"
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Curfew FORCED ON. App sweep + enforcer will engage within a few seconds."
	echo "Validate: open mBank (works), keyboard (works), Firefox (gone). Then: curfew-test-off"
}

cmd_curfew_test_off() {
	rm -f "$CURFEW_FORCE_FILE"
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Curfew force cleared. Back to clock-based behaviour."
}

# Demo mode = the same force mechanism as the test hook, worded for an
# on-demand demo. The companion app's Start/Stop demo button drives the same
# force file. Easy off: curfew-demo-off (or tap "Stop demo curfew").
cmd_curfew_demo_on() {
	touch "$CURFEW_FORCE_FILE"
	chmod 666 "$CURFEW_FORCE_FILE" 2>/dev/null || true
	rm -f "$CURFEW_OVERRIDE_FILE"
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Demo curfew STARTED - full curfew engaged now (apps, grayscale, DND, net)."
	echo "Stop any time with: curfew-demo-off  (or tap 'Stop demo curfew')"
}

cmd_curfew_demo_off() {
	rm -f "$CURFEW_FORCE_FILE"
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Demo curfew STOPPED - back to clock-based behaviour."
}

# Escape hatch: suspend curfew now (the 2am 'let me out' button). Survives
# until you re-arm. Reachable on-device only via ADB (this command) unless a
# root file-manager/terminal has been added to NIGHT_WHITELIST.
cmd_curfew_off() {
	touch "$CURFEW_OVERRIDE_FILE"
	chmod 666 "$CURFEW_OVERRIDE_FILE" 2>/dev/null || true
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Curfew SUSPENDED (override set: $CURFEW_OVERRIDE_FILE). Re-arm with: curfew-on"
}

cmd_curfew_on() {
	rm -f "$CURFEW_OVERRIDE_FILE"
	touch "$RECHECK_TRIGGER" 2>/dev/null || true
	echo "Curfew re-armed (override cleared)."
}
