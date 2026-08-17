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
# shellcheck source=tether_iptables.sh
. "$SCRIPT_DIR/tether_iptables.sh"

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




# ---- Lever 2: FORWARD chain blanket REJECT ----







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
