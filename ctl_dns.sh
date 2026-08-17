#!/system/bin/sh
# shellcheck shell=ash
# ctl_dns.sh — focus_ctl.sh's subcommands for the DNS enforcer:
# status, start, stop and log.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory. Sourced by focus_ctl.sh, which owns log() and the config.sh
# globals these read. The pidfile path below lives here rather than in
# the entry script because this file is its only reader (SC2034), and
# the linter runs without -x, so each file stands alone.

DNS_PIDFILE="$STATE_DIR/dns_enforcer.pid"

dns_enforcer_pid() {
	if [ -f "$DNS_PIDFILE" ]; then
		local pid
		pid="$(cat "$DNS_PIDFILE")"
		if kill -0 "$pid" 2>/dev/null; then
			echo "$pid"
		fi
	fi
}

cmd_dns_status() {
	local pid
	pid="$(dns_enforcer_pid)"
	echo "=== DNS Enforcer Status ==="
	if [ -n "$pid" ]; then
		echo "Daemon:         RUNNING (PID $pid)"
	else
		echo "Daemon:         STOPPED"
	fi
	local mode spec
	mode="$(settings get global private_dns_mode 2>/dev/null)"
	spec="$(settings get global private_dns_specifier 2>/dev/null)"
	echo "private_dns_mode:      ${mode:-<unset>}"
	echo "private_dns_specifier: ${spec:-<unset>}"
	if iptables -L "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
		local v4rules
		v4rules="$(iptables -S "$DNS_IPT_CHAIN" 2>/dev/null | wc -l)"
		echo "iptables $DNS_IPT_CHAIN: $v4rules rules"
	else
		echo "iptables $DNS_IPT_CHAIN: MISSING"
	fi
	if ip6tables -L "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
		local v6rules
		v6rules="$(ip6tables -S "$DNS_IPT_CHAIN" 2>/dev/null | wc -l)"
		echo "ip6tables $DNS_IPT_CHAIN: $v6rules rules"
	else
		echo "ip6tables $DNS_IPT_CHAIN: MISSING"
	fi
}

cmd_dns_start() {
	local pid
	pid="$(dns_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "DNS enforcer already running (PID $pid)"
		return
	fi
	setsid sh "$SCRIPT_DIR/dns_enforcer.sh" </dev/null >/dev/null 2>&1 &
	sleep 2
	pid="$(dns_enforcer_pid)"
	if [ -n "$pid" ]; then
		echo "DNS enforcer started (PID $pid)"
	else
		echo "ERROR: DNS enforcer failed to start. Check log: $DNS_LOG"
	fi
}

cmd_dns_stop() {
	local pid
	pid="$(dns_enforcer_pid)"
	if [ -z "$pid" ]; then
		echo "DNS enforcer not running"
		rm -f "$DNS_PIDFILE"
	else
		kill -TERM "$pid"
		echo "DNS enforcer stopped (sent SIGTERM to PID $pid)"
	fi
	# Explicit teardown of the iptables chain so maintenance work can
	# use DoH. The enforcer itself leaves the chain intact on TERM to
	# keep the block closed between periodic re-applies.
	iptables -D OUTPUT -j "$DNS_IPT_CHAIN" 2>/dev/null || true
	iptables -F "$DNS_IPT_CHAIN" 2>/dev/null || true
	iptables -X "$DNS_IPT_CHAIN" 2>/dev/null || true
	ip6tables -D OUTPUT -j "$DNS_IPT_CHAIN" 2>/dev/null || true
	ip6tables -F "$DNS_IPT_CHAIN" 2>/dev/null || true
	ip6tables -X "$DNS_IPT_CHAIN" 2>/dev/null || true
	echo "iptables chain $DNS_IPT_CHAIN removed"
}

cmd_dns_log() {
	local lines="${1:-50}"
	if [ -f "$DNS_LOG" ]; then
		tail -n "$lines" "$DNS_LOG"
	else
		echo "DNS enforcer log not found: $DNS_LOG"
	fi
}
