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

SCRIPT_DIR="${FOCUS_MODE_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/dns_enforcer.pid"
DNS_BLOCK_IPV4_FILE="$STATE_DIR/dns_block_ipv4.txt"
DNS_BLOCK_IPV6_FILE="$STATE_DIR/dns_block_ipv6.txt"
DNS_BLOCK_UID_FILE="$STATE_DIR/dns_block_uids.txt"

mkdir -p "$STATE_DIR"
touch "$DNS_LOG"
chmod 666 "$DNS_LOG" 2>/dev/null || true

append_unique_line() {
    local file="$1"
    local value="$2"

    [ -z "$value" ] && return 0
    [ -f "$file" ] || : > "$file"

    if ! grep -qxF "$value" "$file" 2>/dev/null; then
        echo "$value" >> "$file"
    fi
}

extract_ping_ip() {
    # Extract the host IP from the first line of ping output:
    #   Ping example.com (1.2.3.4): ...
    #   Ping example.com (2a00:...): ...
    printf '%s\n' "$1" | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p' | head -1
}

extract_package_uid() {
    # Parse one line from `cmd package list packages -U`, e.g.:
    #   package:com.android.chrome uid:10153
    printf '%s\n' "$1" | sed -n 's/.* uid:\([0-9][0-9]*\).*/\1/p' | head -1
}

resolve_package_uid() {
    local pkg="$1"
    local line uid

    line="$(cmd package list packages -U 2>/dev/null | grep -E "^package:${pkg}( |$)" | head -1 || true)"
    uid="$(extract_package_uid "$line")"
    if echo "$uid" | grep -Eq '^[0-9]+$'; then
        echo "$uid"
    fi
}

resolve_ipv4() {
    local host="$1"
    local line ip

    line="$(toybox ping -4 -c 1 -W 1 "$host" 2>/dev/null | head -1 || true)"
    ip="$(extract_ping_ip "$line")"
    if echo "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        echo "$ip"
    fi
}

resolve_ipv6() {
    local host="$1"
    local line ip

    line="$(toybox ping -6 -c 1 -W 1 "$host" 2>/dev/null | head -1 || true)"
    ip="$(extract_ping_ip "$line")"
    if echo "$ip" | grep -Eq '^[0-9A-Fa-f:]+$'; then
        echo "$ip"
    fi
}

refresh_blocked_content_ips() {
    : > "$DNS_BLOCK_IPV4_FILE"
    : > "$DNS_BLOCK_IPV6_FILE"

    local host ip4 ip6
    for host in $DNS_BLOCK_HOSTS; do
        [ -z "$host" ] && continue
        [ "${host#\#}" != "$host" ] && continue

        ip4="$(resolve_ipv4 "$host")"
        ip6="$(resolve_ipv6 "$host")"

        append_unique_line "$DNS_BLOCK_IPV4_FILE" "$ip4"
        append_unique_line "$DNS_BLOCK_IPV6_FILE" "$ip6"
    done
}

refresh_blocked_app_uids() {
    : > "$DNS_BLOCK_UID_FILE"

    local pkg uid
    # Always-blocked packages (hard distractions: YouTube, Chrome, ...).
    for pkg in $DNS_BLOCK_PACKAGES_ALWAYS; do
        [ -z "$pkg" ] && continue
        [ "${pkg#\#}" != "$pkg" ] && continue

        uid="$(resolve_package_uid "$pkg")"
        append_unique_line "$DNS_BLOCK_UID_FILE" "$uid"
    done

    # Focus-mode-only packages (Play Store etc. - usable outside focus mode).
    if [ "$(cat "$MODE_FILE" 2>/dev/null)" = "focus" ]; then
        for pkg in $DNS_BLOCK_PACKAGES_FOCUS_ONLY; do
            [ -z "$pkg" ] && continue
            [ "${pkg#\#}" != "$pkg" ] && continue

            uid="$(resolve_package_uid "$pkg")"
            append_unique_line "$DNS_BLOCK_UID_FILE" "$uid"
        done
    fi
}

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

    # Content-block fallback: reject HTTP/HTTPS to resolved endpoints of
    # DNS_BLOCK_HOSTS. This is used on ROMs where hosts-file enforcement is
    # impossible (no writable hosts inode on read-only partitions).
    if [ -f "$DNS_BLOCK_IPV4_FILE" ]; then
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 80  -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 443 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            iptables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 443 -j REJECT \
                --reject-with icmp-port-unreachable 2>/dev/null || true
        done < "$DNS_BLOCK_IPV4_FILE"
    fi

    # App-level web block: block HTTP/HTTPS for selected package UIDs.
    # Only ports 80 and 443 are blocked so DNS (port 53) and system services
    # still work — the apps just can't load web content or stream video.
    if [ -f "$DNS_BLOCK_UID_FILE" ]; then
        while IFS= read -r uid; do
            [ -z "$uid" ] && continue
            iptables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p tcp --dport 80 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            iptables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p tcp --dport 443 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            iptables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT \
                --reject-with icmp-port-unreachable 2>/dev/null || true
        done < "$DNS_BLOCK_UID_FILE"
    fi
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

    if [ -f "$DNS_BLOCK_IPV6_FILE" ]; then
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 80  -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p tcp --dport 443 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "$DNS_IPT_CHAIN" -d "$ip" -p udp --dport 443 -j REJECT \
                --reject-with icmp6-port-unreachable 2>/dev/null || true
        done < "$DNS_BLOCK_IPV6_FILE"
    fi

    if [ -f "$DNS_BLOCK_UID_FILE" ]; then
        while IFS= read -r uid; do
            [ -z "$uid" ] && continue
            ip6tables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p tcp --dport 80 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p tcp --dport 443 -j REJECT \
                --reject-with tcp-reset 2>/dev/null || true
            ip6tables -A "$DNS_IPT_CHAIN" -m owner --uid-owner "$uid" -p udp --dport 443 -j REJECT \
                --reject-with icmp6-port-unreachable 2>/dev/null || true
        done < "$DNS_BLOCK_UID_FILE"
    fi
}

enforce_iptables() {
    refresh_blocked_content_ips
    refresh_blocked_app_uids

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

if [ "${FOCUS_MODE_DNS_ENFORCER_TESTING:-0}" != "1" ]; then
    main "$@"
fi
