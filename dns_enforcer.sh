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
    echo "[$ts] $1" >> "$DNS_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$DNS_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$DNS_LOG.tmp"
        tail -n 500 "$DNS_LOG" > "$tmp"
        mv "$tmp" "$DNS_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "dns_enforcer"; then
                echo "dns_enforcer already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# ---- Private DNS ----

ensure_private_dns_off() {
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
    # Ensure OUTPUT references our chain exactly once.
    if ! "$ipt" -C OUTPUT -j "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
        "$ipt" -I OUTPUT 1 -j "$DNS_IPT_CHAIN" 2>/dev/null || {
            log "ERROR: could not insert OUTPUT -> $DNS_IPT_CHAIN for $ipt"
            return 1
        }
        log "Linked OUTPUT -> $DNS_IPT_CHAIN ($ipt)"
    fi
}

fill_chain_v4() {
    # Flush and refill so we always converge to the intended rule set.
    iptables -F "$DNS_IPT_CHAIN" 2>/dev/null || return 1
    # Drop DoT everywhere. This is a narrow port rule - there's no legit
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
        iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 53  -j REJECT \
            --reject-with icmp-port-unreachable 2>/dev/null || true
        iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 53  -j REJECT \
            --reject-with tcp-reset 2>/dev/null || true
    done
}

fill_chain_v6() {
    ip6tables -F "$DNS_IPT_CHAIN" 2>/dev/null || return 1
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
        ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 53  -j REJECT \
            --reject-with icmp6-port-unreachable 2>/dev/null || true
        ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 53  -j REJECT \
            --reject-with tcp-reset 2>/dev/null || true
    done
}

enforce_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        ensure_chain iptables && fill_chain_v4
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ensure_chain ip6tables && fill_chain_v6
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
