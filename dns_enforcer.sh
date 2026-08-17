#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# DNS enforcer for rooted Android.
#
# Why this exists:
#   /etc/hosts only works for lookups done by the *system* resolver
#   using classic DNS (UDP/TCP 53). Two bypass channels defeat it:
#     1. DNS-over-TLS (DoT, port 853) - used by Android when Private
#        DNS is "automatic" or set to a specific provider.
#     2. DNS-over-HTTPS (DoH, port 443) - used by Chrome/Brave's
#        "Use secure DNS" feature and some apps directly.
#
# Strategy:
#   1. Force `settings global private_dns_mode off` so the OS stops
#      doing DoT (there is no public DoT-by-hostname toggle).
#   2. Drop outbound traffic to a fixed list of well-known DoH/DoT
#      endpoints via iptables / ip6tables so apps' fallback logic
#      has to use the regular resolver, which consults /etc/hosts.
#
# Limitations:
#   * A custom app that hardcodes an obscure DoH IP is not caught.
#   * A root user can `iptables -F` or re-enable private DNS - but
#     this loop re-asserts every $DNS_CHECK_INTERVAL seconds and
#     leaves tamper logs.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# Sourced after config.sh because the chain functions read its DNS_* values.
# They also call log(), defined below; that is fine because nothing in either
# file runs until main() does. A sibling, not a lib/ member: lib/ does not
# exist on the phone, and deploy.sh copies these scripts flat into $REMOTE_DIR.
# shellcheck source=dns_iptables.sh
. "$SCRIPT_DIR/dns_iptables.sh"

PIDFILE="$STATE_DIR/dns_enforcer.pid"

mkdir -p "$STATE_DIR"
touch "$DNS_LOG"
chmod 666 "$DNS_LOG" 2>/dev/null || true

log() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$ts] $1" >>"$DNS_LOG"
}

rotate_log() {
	local lines
	lines="$(wc -l <"$DNS_LOG" 2>/dev/null || echo 0)"
	if [ "$lines" -gt 500 ]; then
		local tmp="$DNS_LOG.tmp"
		tail -n 500 "$DNS_LOG" >"$tmp"
		mv "$tmp" "$DNS_LOG"
	fi
}

acquire_lock() {
	if [ -f "$PIDFILE" ]; then
		local old_pid
		old_pid="$(cat "$PIDFILE")"
		if kill -0 "$old_pid" 2>/dev/null; then
			local cmdline
			cmdline="$(tr '\0' ' ' <"/proc/$old_pid/cmdline" 2>/dev/null)"
			if echo "$cmdline" | grep -q "dns_enforcer"; then
				echo "dns_enforcer already running (PID $old_pid)"
				exit 0
			fi
		fi
		rm -f "$PIDFILE"
	fi
	echo $$ >"$PIDFILE"
}

# ---- Private DNS ----

ensure_private_dns_off() {
	# Two modes, selected by DNS_TRUSTED_DOT_HOST:
	#
	#   empty  - the original behaviour. DoT is a bypass channel, so Private
	#            DNS is forced off and every 853 connection is rejected.
	#   set    - DoT is the *enforcement* channel. Private DNS is pinned to
	#            our own filtering resolver, and pinning it is what stops the
	#            user picking an unfiltered one from Settings.
	#
	# The pinned case is what an unrooted phone needs, since it has no hosts
	# file to fall back to.
	if [ -n "${DNS_TRUSTED_DOT_HOST:-}" ]; then
		ensure_private_dns_pinned
		return
	fi

	local mode
	mode="$(settings get global private_dns_mode 2>/dev/null)"
	# Possible values: "off", "opportunistic", "hostname", null (default=opportunistic)
	if [ "$mode" != "off" ]; then
		settings put global private_dns_mode off 2>/dev/null
		log "Private DNS was '$mode' - forced to 'off'"
	fi
	# Clear any pinned DoT hostname so the "hostname" mode cannot be
	# re-enabled silently by Settings UI.
	local spec
	spec="$(settings get global private_dns_specifier 2>/dev/null)"
	if [ -n "$spec" ] && [ "$spec" != "null" ]; then
		settings delete global private_dns_specifier 2>/dev/null
		log "Cleared private_dns_specifier (was '$spec')"
	fi
}

ensure_private_dns_pinned() {
	# Hold Private DNS on our own resolver. Re-asserted every check, so a
	# change made in Settings is reverted within DNS_CHECK_INTERVAL.
	local mode spec
	spec="$(settings get global private_dns_specifier 2>/dev/null)"
	if [ "$spec" != "$DNS_TRUSTED_DOT_HOST" ]; then
		settings put global private_dns_specifier "$DNS_TRUSTED_DOT_HOST" 2>/dev/null
		log "private_dns_specifier was '$spec' - pinned to '$DNS_TRUSTED_DOT_HOST'"
	fi
	# Set the specifier before the mode: switching to "hostname" while the
	# specifier still names someone else would briefly route lookups through
	# that other resolver.
	mode="$(settings get global private_dns_mode 2>/dev/null)"
	if [ "$mode" != "hostname" ]; then
		settings put global private_dns_mode hostname 2>/dev/null
		log "Private DNS was '$mode' - forced to 'hostname'"
	fi
}

# ---- iptables chain management ----

# ---- State-change gate ----
#
# fill_chain_v4/v6 flush and reinsert ~50-100 iptables/ip6tables rules each
# call. Running that unconditionally every $DNS_CHECK_INTERVAL was measured
# to peg netd at ~50% CPU on-device (contending the xtables lock) even
# though the rule set never changes at runtime. Only rebuild when the chain
# is actually missing, untethered from OUTPUT, or the wrong size (i.e.
# someone/something - netd, a root shell, a flush - tampered with it).
# Self-healing behavior described in the header comment is preserved; only
# redundant identical rebuilds are skipped.

cleanup() {
	# We intentionally leave the iptables chain in place on SIGTERM so
	# stopping the enforcer for maintenance does not immediately re-open
	# the DoH hole. `focus_ctl.sh dns-stop` does the explicit teardown.
	log "dns_enforcer shutting down"
	rm -f "$PIDFILE"
	exit 0
}

trap cleanup INT TERM

main() {
	acquire_lock
	log "dns_enforcer started (PID=$$)"

	# Initial arm-up
	ensure_private_dns_off
	enforce_iptables

	while true; do
		ensure_private_dns_off
		enforce_iptables
		rotate_log
		sleep "$DNS_CHECK_INTERVAL"
	done
}

main "$@"
