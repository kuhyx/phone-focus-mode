#!/system/bin/sh
# shellcheck shell=ash
# curfew_net.sh — the network layer of the night curfew: the per-UID
# iptables allow-list that cuts every app outside $NIGHT_WHITELIST off the
# network while the curfew is open. Default OFF ($CURFEW_NET_ENABLED).
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one
# directory, which is why dns_iptables.sh and tether_iptables.sh live
# beside their enforcers too.
#
# Sourced by curfew_enforcer.sh, which owns log(), the config.sh globals
# these read ($CURFEW_NET_*, $NIGHT_WHITELIST, $STATE_DIR) and $NET_BUILT,
# the build-once flag both files write.

# Resolve the UIDs of the night-whitelisted packages. Apps not installed are
# silently skipped. Output: one numeric UID per line.
night_uids() {
    local plist="$STATE_DIR/night_whitelist.txt"
    [ -f "$plist" ] || return 0
    # `pm list packages -U` lines look like: "package:com.foo uid:10123"
    local map="$STATE_DIR/uid_map.txt"
    pm list packages -U 2>/dev/null \
        | sed 's/^package://' > "$map"
    # Piped rather than redirected on `done`: kcov instruments a trailing
    # `done < file` as a line bash never reports, which alone held this file
    # below 100%. The loop only writes to stdout, so running it in the pipe's
    # subshell changes nothing — unlike the pull_apks case in
    # backup_capture.sh, nothing inside here consumes stdin.
    cat "$plist" | while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        awk -v p="$pkg" '$1 == p { sub(/uid:/,"",$2); print $2 }' "$map"
    done
    rm -f "$map"
}

ensure_net_chain() {
    local ipt="$1"
    if ! iptw "$ipt" -L "$CURFEW_NET_IPT_CHAIN" >/dev/null 2>&1; then
        iptw "$ipt" -N "$CURFEW_NET_IPT_CHAIN" 2>/dev/null || return 1
    fi
    # De-dupe and pin exactly one OUTPUT jump at position 1.
    while iptw "$ipt" -D OUTPUT -j "$CURFEW_NET_IPT_CHAIN" 2>/dev/null; do :; done
    iptw "$ipt" -I OUTPUT 1 -j "$CURFEW_NET_IPT_CHAIN" 2>/dev/null || return 1
}

fill_net_chain() {
    local ipt="$1" reject="$2"
    iptw "$ipt" -F "$CURFEW_NET_IPT_CHAIN" 2>/dev/null || return 1
    # Always-allowed plumbing: loopback, established flows, the OS itself, the
    # daemon/ADB (root + shell), and DNS (apps resolve via netd, a different
    # uid, so allow port 53 broadly or every lookup fails under the cut-off).
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -o lo -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner 0 -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner 1000 -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner 2000 -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    # Allow each whitelisted app UID, read from the cache (refreshed once per
    # main tick). Reading the cache instead of calling night_uids() here keeps
    # the fast watchdog fork-free (no `pm list packages` on every rebuild).
    local uid
    if [ -f "$CURFEW_NET_UID_CACHE" ]; then
        # Piped for the same reason as night_uids above: a trailing
        # `done < file` is a line kcov counts and bash never reports. The
        # loop's only effect is the iptw calls, which are external commands,
        # so the pipe's subshell is immaterial here.
        cat "$CURFEW_NET_UID_CACHE" | while IFS= read -r uid; do
            case "$uid" in ''|*[!0-9]*) continue ;; esac
            iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner "$uid" -j ACCEPT 2>/dev/null || true
        done
    fi
    # Cut off every remaining ordinary APP uid (10000-19999 = user-0 app range).
    # Scoped to the app range so kernel/system sockets (no owner / low uids) are
    # never touched — far safer than a blanket default-DROP.
    iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner 10000-19999 -j REJECT \
        --reject-with "$reject" 2>/dev/null || true
}

# Run iptables/ip6tables with a 2s xtables lock-wait. Android's netd runs its
# own concurrent `iptables-restore`; without -w our calls silently fail the
# instant netd holds the lock (proven on-device: partial 19-rule chains and
# multi-second outages). -w queues for the lock so our calls actually land.
# iptables 1.8.7 legacy supports it. $1 = binary (iptables/ip6tables).
iptw() {
    local bin="$1"
    shift
    "$bin" -w 2 "$@"
}

# Refresh the cached UID list (one `pm list packages -U` fork). Called once per
# main tick so the fast watchdog can rebuild from the cache without forking.
refresh_uid_cache() {
    if night_uids > "$CURFEW_NET_UID_CACHE.tmp" 2>/dev/null; then
        mv "$CURFEW_NET_UID_CACHE.tmp" "$CURFEW_NET_UID_CACHE" 2>/dev/null || true
    fi
}

# Rebuild the chain from cache for whichever iptables variants exist. No pm fork.
rebuild_net_from_cache() {
    if command -v iptables >/dev/null 2>&1; then
        ensure_net_chain iptables && fill_net_chain iptables icmp-port-unreachable
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ensure_net_chain ip6tables && fill_net_chain ip6tables icmp6-port-unreachable
    fi
}

# Fast watchdog: for `total` seconds, every CURFEW_NET_REASSERT_INTERVAL check
# whether netd wiped our chain and, if so, re-pin it from cache. Replaces the
# plain inter-tick sleep while curfew is active so the leak window drops from
# the full 5s tick to <=1s. Echoes the number of rebuilds it performed.
net_hold() {
    local total="$1" elapsed=0 rebuilds=0 step="${CURFEW_NET_REASSERT_INTERVAL:-1}"
    while [ "$elapsed" -lt "$total" ]; do
        sleep "$step"
        elapsed=$((elapsed + step))
        if command -v iptables >/dev/null 2>&1 \
            && ! iptw iptables -L "$CURFEW_NET_IPT_CHAIN" >/dev/null 2>&1; then
            rebuild_net_from_cache
            rebuilds=$((rebuilds + 1))
        fi
    done
    echo "$rebuilds"
}

apply_net() {
    [ "${CURFEW_NET_ENABLED:-0}" = "1" ] || return 0
    refresh_uid_cache
    # Discriminating probe: if we already built the chain on a prior tick but it
    # is gone now, an external actor wiped it (Android netd rewriting the filter
    # table, or a manual flush during debugging). Log each disappearance so the
    # live test reads "flush + self-heal" vs "dead process" directly, instead of
    # inferring it from log silence.
    if [ -n "$NET_BUILT" ] && command -v iptables >/dev/null 2>&1 \
        && ! iptables -L "$CURFEW_NET_IPT_CHAIN" >/dev/null 2>&1; then
        log "net chain $CURFEW_NET_IPT_CHAIN vanished since last tick - rebuilding (external flush?)"
    fi
    if command -v iptables >/dev/null 2>&1; then
        ensure_net_chain iptables && fill_net_chain iptables icmp-port-unreachable
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ensure_net_chain ip6tables && fill_net_chain ip6tables icmp6-port-unreachable
    fi
    NET_BUILT=1
}

teardown_net() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while iptw "$ipt" -D OUTPUT -j "$CURFEW_NET_IPT_CHAIN" 2>/dev/null; do :; done
        iptw "$ipt" -F "$CURFEW_NET_IPT_CHAIN" 2>/dev/null || true
        iptw "$ipt" -X "$CURFEW_NET_IPT_CHAIN" 2>/dev/null || true
    done
}
