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

ensure_chain() {
	local ipt="$1"
	# Create the chain if missing.
	if ! "$ipt" -L "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
		"$ipt" -N "$DNS_IPT_CHAIN" 2>/dev/null || {
			log "ERROR: could not create $ipt chain $DNS_IPT_CHAIN"
			return 1
		}
		log "Created $ipt chain $DNS_IPT_CHAIN"
	fi
	# Remove ALL existing OUTPUT -> chain jumps (handles duplicates from
	# previous iptables lock races where -C returned error but -I succeeded).
	local removed=0
	while "$ipt" -D OUTPUT -j "$DNS_IPT_CHAIN" 2>/dev/null; do
		removed=$((removed + 1))
	done
	# Insert exactly one jump at position 1 of OUTPUT.
	if "$ipt" -I OUTPUT 1 -j "$DNS_IPT_CHAIN" 2>/dev/null; then
		if [ "$removed" -gt 1 ]; then
			log "De-duped $removed -> 1 OUTPUT jump for $ipt chain $DNS_IPT_CHAIN"
		fi
	else
		log "ERROR: could not insert OUTPUT -> $DNS_IPT_CHAIN for $ipt"
		return 1
	fi
}

trusted_dot_ips() {
	# Echo the trusted resolver's addresses of the given family, one per line.
	# $1 is "4" or "6". Literals come from DNS_TRUSTED_DOT_IPS; anything else
	# is ignored, because resolving the resolver's own name here would be
	# circular once Private DNS is pinned to it.
	local want="$1" ip
	[ -z "${DNS_TRUSTED_DOT_HOST:-}" ] && return 0
	for ip in ${DNS_TRUSTED_DOT_IPS:-}; do
		[ -z "$ip" ] && continue
		[ "${ip#\#}" != "$ip" ] && continue
		case "$ip" in
		*:*) [ "$want" = "6" ] && printf '%s\n' "$ip" ;;
		*) [ "$want" = "4" ] && printf '%s\n' "$ip" ;;
		esac
	done
}

fill_chain_v4() {
	# Flush and refill so we always converge to the intended rule set.
	iptables -F "$DNS_IPT_CHAIN" 2>/dev/null || return 1
	# Allow the one DoT resolver we trust, BEFORE the blanket reject below.
	# Order matters: iptables takes the first match, so an ACCEPT appended
	# after the REJECT would never be reached.
	local trusted
	for trusted in $(trusted_dot_ips 4); do
		iptables -A "$DNS_IPT_CHAIN" -d "$trusted" -p tcp --dport 853 \
			-j ACCEPT 2>/dev/null || true
	done
	# Drop DoT everywhere else. This is a narrow port rule - there's no legit
	# reason for arbitrary apps to talk 853/tcp on Android.
	iptables -A "$DNS_IPT_CHAIN" -p tcp --dport 853 -j REJECT \
		--reject-with tcp-reset 2>/dev/null || true
	iptables -A "$DNS_IPT_CHAIN" -p udp --dport 853 -j REJECT \
		--reject-with icmp-port-unreachable 2>/dev/null || true

	local ip
	for ip in $DNS_DOH_IPV4; do
		[ -z "$ip" ] && continue
		[ "${ip#\#}" != "$ip" ] && continue
		# Reject 443/tcp (DoH) and 53 (classic DNS) to well-known resolvers.
		# We also block 53 so apps that try to talk to 1.1.1.1:53 directly
		# (ignoring /etc/resolv.conf) still fall back to the system resolver.
		iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 443 -j REJECT \
			--reject-with tcp-reset 2>/dev/null || true
		iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 443 -j REJECT \
			--reject-with icmp-port-unreachable 2>/dev/null || true
		iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 53 -j REJECT \
			--reject-with icmp-port-unreachable 2>/dev/null || true
		iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 53 -j REJECT \
			--reject-with tcp-reset 2>/dev/null || true
	done
}

fill_chain_v6() {
	ip6tables -F "$DNS_IPT_CHAIN" 2>/dev/null || return 1
	local trusted
	for trusted in $(trusted_dot_ips 6); do
		ip6tables -A "$DNS_IPT_CHAIN" -d "$trusted" -p tcp --dport 853 \
			-j ACCEPT 2>/dev/null || true
	done
	ip6tables -A "$DNS_IPT_CHAIN" -p tcp --dport 853 -j REJECT \
		--reject-with tcp-reset 2>/dev/null || true
	ip6tables -A "$DNS_IPT_CHAIN" -p udp --dport 853 -j REJECT \
		--reject-with icmp6-port-unreachable 2>/dev/null || true

	local ip
	for ip in $DNS_DOH_IPV6; do
		[ -z "$ip" ] && continue
		[ "${ip#\#}" != "$ip" ] && continue
		ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 443 -j REJECT \
			--reject-with tcp-reset 2>/dev/null || true
		ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 443 -j REJECT \
			--reject-with icmp6-port-unreachable 2>/dev/null || true
		ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 53 -j REJECT \
			--reject-with icmp6-port-unreachable 2>/dev/null || true
		ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 53 -j REJECT \
			--reject-with tcp-reset 2>/dev/null || true
	done
}

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

expected_rule_count() {
	# 2 fixed DoT rules (tcp+udp/853) + 4 rules per configured DoH/DNS IP,
	# plus 1 ACCEPT per trusted-resolver address of this family. $1 is the
	# family ("4"/"6"); the remaining arguments are the DoH/DNS IPs.
	#
	# This has to match fill_chain_* exactly. chain_intact() compares the
	# live rule count against this number and rebuilds on any mismatch, so
	# an undercount here means a rebuild every DNS_CHECK_INTERVAL seconds --
	# a silent fork storm that also drops the connection each time.
	local family="$1"
	shift
	local n=2 ip
	for ip in "$@"; do
		[ -z "$ip" ] && continue
		[ "${ip#\#}" != "$ip" ] && continue
		n=$((n + 4))
	done
	for ip in $(trusted_dot_ips "$family"); do
		n=$((n + 1))
	done
	echo "$n"
}

chain_intact() {
	local ipt="$1" expected="$2" actual
	"$ipt" -C OUTPUT -j "$DNS_IPT_CHAIN" >/dev/null 2>&1 || return 1
	actual="$("$ipt" -S "$DNS_IPT_CHAIN" 2>/dev/null | grep -c '^-A')"
	[ "$actual" = "$expected" ]
}

enforce_iptables() {
	if command -v iptables >/dev/null 2>&1; then
		# Intentional word split: expected_rule_count() iterates "$@" over the
		# configured IP list. This runs under /system/bin/sh on the phone, where
		# arrays do not exist, so an unquoted expansion is the POSIX way to do it.
		# shellcheck disable=SC2086
		if chain_intact iptables "$(expected_rule_count 4 $DNS_DOH_IPV4)"; then
			:
		elif ensure_chain iptables && fill_chain_v4; then
			log "iptables (v4) DNS chain rebuilt (was missing/tampered)"
		fi
	fi
	if command -v ip6tables >/dev/null 2>&1; then
		# Intentional word split, as above.
		# shellcheck disable=SC2086
		if chain_intact ip6tables "$(expected_rule_count 6 $DNS_DOH_IPV6)"; then
			:
		elif ensure_chain ip6tables && fill_chain_v6; then
			log "ip6tables (v6) DNS chain rebuilt (was missing/tampered)"
		fi
	fi
}

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
