#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Hotspot / tethering enforcer for rooted Android.
#
# Why this exists:
#   Every other network layer here only filters THIS phone's own traffic:
#   /system/etc/hosts is consulted by the phone's system resolver, and both
#   dns_enforcer and the curfew net layer only touch the OUTPUT chain. When the
#   phone shares its mobile data as a WiFi/USB/BT hotspot, the tethered device's
#   packets are FORWARDed + NAT'd through us on a path none of that covers - so
#   a second phone browses freely and defeats focus mode entirely.
#
# Strategy (belt-and-suspenders; all best-effort, converged every tick):
#   1. Disable tether offload (settings global) so forwarded traffic is not
#      shunted around netfilter by the hardware/BPF fast path.
#   2. Blanket REJECT of the FORWARD chain (iptables + ip6tables). This is the
#      version-independent catch-all and covers WiFi, USB and BT tethering.
#      The phone's own traffic uses OUTPUT/INPUT, never FORWARD, so normal
#      connectivity is untouched.
#   3. Best-effort actively stop a running softAP (WiFi only; Android 11+) so
#      the hotspot toggle visibly flips back off.
#
# Acts ONLY while focus mode is ON ($MODE_FILE == "focus", i.e. at home) or the
# force-test file is present. On the transition away from home it restores the
# offload snapshot and tears the FORWARD chain down, leaving tethering usable.
#
# "Locked" = snap-back: re-toggling the hotspot on is reverted within one tick.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/tether_enforcer.pid"

mkdir -p "$STATE_DIR"
touch "$TETHER_LOG"
chmod 666 "$TETHER_LOG" 2>/dev/null || true

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$TETHER_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$TETHER_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$TETHER_LOG.tmp"
        tail -n 500 "$TETHER_LOG" > "$tmp"
        mv "$tmp" "$TETHER_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "tether_enforcer"; then
                echo "tether_enforcer already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# ---- Activation gate (mirrors curfew_enforcer.sh::should_act) ----

at_home() {
    [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE" 2>/dev/null)" = "focus" ]
}

should_act() {
    [ "${TETHER_ENFORCER_ENABLED:-0}" = "1" ] || return 1
    [ -e "$TETHER_OVERRIDE_FILE" ] && return 1
    # Force hook bypasses the home gate so the full stack can be validated
    # during the day from anywhere (`focus_ctl.sh tether-test-on`).
    [ -e "$TETHER_FORCE_FILE" ] && return 0
    at_home
}

# ---- Lever 1: tether offload ----

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

# ---- Lever 2: FORWARD chain blanket REJECT ----

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

# ---- Lever 3: actively stop the softAP (best-effort, WiFi only) ----

_android_major() {
    local ver="${1%%.*}"
    case "$ver" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$ver" ;;
    esac
}

stop_softap() {
    [ "${TETHER_STOP_SOFTAP_ENABLED:-0}" = "1" ] || return 0
    command -v cmd >/dev/null 2>&1 || return 0
    local major
    major="$(_android_major "$(getprop ro.build.version.release 2>/dev/null)")"
    # `cmd wifi stop-softap` landed in Android 11. Best-effort, idempotent: it
    # no-ops (non-zero) when no softAP is running, which we intentionally ignore.
    if [ "$major" -ge 11 ]; then
        cmd wifi stop-softap >/dev/null 2>&1 || true
    else
        cmd wifi set-wifi-ap-enabled false >/dev/null 2>&1 || true
    fi
}

# ---- Apply / revert orchestration ----

enter_block() {
    if [ ! -e "$TETHER_ENFORCER_STATE" ]; then
        snapshot_offload
        : > "$TETHER_ENFORCER_STATE"
        log "Tether block ON (focus mode) - offload off + FORWARD reject${TETHER_STOP_SOFTAP_ENABLED:+ + stop-softap}"
    fi
    apply_offload_off
    apply_forward_block
    stop_softap
}

exit_block() {
    [ -e "$TETHER_ENFORCER_STATE" ] || return 0
    restore_offload
    teardown_forward_block
    rm -f "$TETHER_ENFORCER_STATE"
    log "Tether block OFF - restored offload, tore down FORWARD chain"
}

cleanup() {
    # Clean stop leaves tethering usable again (the intuitive escape hatch:
    # `focus_ctl.sh tether-stop`).
    log "tether_enforcer shutting down - reverting"
    exit_block
    rm -f "$PIDFILE"
    exit 0
}

trap cleanup INT TERM

main() {
    acquire_lock
    log "tether_enforcer started (PID=$$, enabled=${TETHER_ENFORCER_ENABLED})"
    local tick=0 act fwd
    while true; do
        if should_act; then act=1; enter_block; else act=0; exit_block; fi
        # Heartbeat every ~6 ticks (~30s) so "alive but idle" is distinguishable
        # from "dead" in the log.
        tick=$((tick + 1))
        if [ "$((tick % 6))" -eq 0 ]; then
            if iptw iptables -C FORWARD -j "$TETHER_IPT_CHAIN" >/dev/null 2>&1; then
                fwd=up
            else
                fwd=down
            fi
            log "heartbeat tick=$tick act=$act forward=$fwd"
        fi
        rotate_log
        sleep "$TETHER_CHECK_INTERVAL"
    done
}

main "$@"
