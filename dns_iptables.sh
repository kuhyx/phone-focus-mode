#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# dns_iptables.sh — the iptables chain half of dns_enforcer.sh.
#
# Builds and maintains the DNS_IPT_CHAIN block chain: creating it and
# pinning a single OUTPUT jump, filling it for IPv4 and IPv6, computing
# the rule count that proves it is complete, and re-asserting it when it
# has drifted.
#
# Sourced by dns_enforcer.sh after config.sh, whose DNS_* values these
# functions read. They also call log(), which dns_enforcer.sh defines;
# nothing here runs until main() calls it, so definition order is fine.
# A sibling rather than a lib/ member: lib/ does not exist on the phone,
# and deploy.sh copies these scripts flat into $REMOTE_DIR.
# ============================================================

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
