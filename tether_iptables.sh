#!/system/bin/sh
# shellcheck shell=ash
# iptables chain management and tethering-offload control for tether_enforcer.
#
# A sibling file rather than a lib/ member: deploy.sh copies a hardcoded
# per-file list into REMOTE_DIR and never deploys lib/, so anything sourced on
# the phone must sit beside the entry script and be listed there too.

apply_offload_off() {
    local cur
    cur="$(settings get global "$TETHER_OFFLOAD_KEY" 2>/dev/null)"
    if [ "$cur" != "1" ]; then
        settings put global "$TETHER_OFFLOAD_KEY" 1 2>/dev/null \
            && log "tether offload was '$cur' - forced disabled (=1)"
    fi
}

snapshot_offload() {
    local cur
    cur="$(settings get global "$TETHER_OFFLOAD_KEY" 2>/dev/null)"
    printf '%s\n' "${cur:-null}" > "$TETHER_OFFLOAD_SNAP" 2>/dev/null || true
}

restore_offload() {
    local snap
    [ -f "$TETHER_OFFLOAD_SNAP" ] && snap="$(cat "$TETHER_OFFLOAD_SNAP" 2>/dev/null)"
    case "$snap" in
        ''|null)
            # No pre-existing value: clear ours so the OS default returns.
            settings delete global "$TETHER_OFFLOAD_KEY" 2>/dev/null || true
            ;;
        *)
            settings put global "$TETHER_OFFLOAD_KEY" "$snap" 2>/dev/null || true
            ;;
    esac
}

# Run iptables/ip6tables with a 2s xtables lock-wait so our calls queue for the
# lock instead of silently failing the instant netd holds it (proven necessary
# on-device for the curfew net layer). $1 = binary.
iptw() {
    local bin="$1"
    shift
    "$bin" -w 2 "$@"
}

ensure_chain() {
    local ipt="$1"
    if ! iptw "$ipt" -L "$TETHER_IPT_CHAIN" >/dev/null 2>&1; then
        iptw "$ipt" -N "$TETHER_IPT_CHAIN" 2>/dev/null || {
            log "ERROR: could not create $ipt chain $TETHER_IPT_CHAIN"
            return 1
        }
    fi
    # De-dupe: remove every existing FORWARD jump, then pin exactly one at #1
    # (netd inserts its own tethering rules into FORWARD, so we must be first).
    while iptw "$ipt" -D FORWARD -j "$TETHER_IPT_CHAIN" 2>/dev/null; do :; done
    iptw "$ipt" -I FORWARD 1 -j "$TETHER_IPT_CHAIN" 2>/dev/null || {
        log "ERROR: could not insert FORWARD -> $TETHER_IPT_CHAIN for $ipt"
        return 1
    }
}

fill_chain() {
    local ipt="$1" reject="$2"
    iptw "$ipt" -F "$TETHER_IPT_CHAIN" 2>/dev/null || return 1
    # Single rule: reject everything that would be forwarded through us.
    iptw "$ipt" -A "$TETHER_IPT_CHAIN" -j REJECT --reject-with "$reject" 2>/dev/null || true
}

# Only rebuild when actually tampered (chain missing, unlinked from FORWARD, or
# wrong size). Avoids forking a flush+refill every tick, which pegs netd.
chain_intact() {
    local ipt="$1" actual
    iptw "$ipt" -C FORWARD -j "$TETHER_IPT_CHAIN" >/dev/null 2>&1 || return 1
    actual="$(iptw "$ipt" -S "$TETHER_IPT_CHAIN" 2>/dev/null | grep -c '^-A')"
    [ "$actual" = "1" ]
}

apply_forward_block() {
    if command -v iptables >/dev/null 2>&1; then
        if chain_intact iptables; then :; \
        elif ensure_chain iptables && fill_chain iptables icmp-port-unreachable; then
            log "iptables (v4) FORWARD block rebuilt (was missing/tampered)"
        fi
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if chain_intact ip6tables; then :; \
        elif ensure_chain ip6tables && fill_chain ip6tables icmp6-port-unreachable; then
            log "ip6tables (v6) FORWARD block rebuilt (was missing/tampered)"
        fi
    fi
}

teardown_forward_block() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while iptw "$ipt" -D FORWARD -j "$TETHER_IPT_CHAIN" 2>/dev/null; do :; done
        iptw "$ipt" -F "$TETHER_IPT_CHAIN" 2>/dev/null || true
        iptw "$ipt" -X "$TETHER_IPT_CHAIN" 2>/dev/null || true
    done
}
