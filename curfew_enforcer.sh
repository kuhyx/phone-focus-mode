#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Night-curfew enforcer for rooted Android.
#
# Companion to focus_daemon.sh. The daemon handles the APP layer (disabling
# everything not in $NIGHT_WHITELIST while the curfew window is open at home).
# This enforcer adds the three "make the phone boring + unreachable" layers and
# keeps them locked by re-applying every $CURFEW_ENFORCER_INTERVAL seconds:
#
#   1. Grayscale   - force the display monochrome via the accessibility
#                    daltonizer. The single biggest behavioural deterrent.
#   2. DND         - force Do-Not-Disturb to alarms-only so notifications stop
#                    pulling you back in, while the morning alarm still rings.
#   3. Net curfew  - (default OFF) per-UID iptables allow-list: only the
#                    $NIGHT_WHITELIST app UIDs (plus root/system/shell + DNS)
#                    get network; every other app is cut off.
#
# "Locked" = snap-back: a manual toggle in Settings is reverted within one
# interval. True impossibility would require blocking the Settings app, which
# risks system instability, so we deliberately do not.
#
# Acts ONLY while curfew is active (time window or forced) AND, for the
# non-forced case, while focus mode is ON (i.e. you are at home). On the
# transition back to day it restores the snapshotted display/DND state and
# tears the iptables chain down, so daytime is left exactly as it was.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/curfew_enforcer.pid"
# Snapshot of the user's pre-curfew display/DND state, captured on entry and
# restored on exit so we never clobber settings we did not set.
GRAYSCALE_SNAP="$STATE_DIR/curfew_grayscale.snap"

mkdir -p "$STATE_DIR"
touch "$CURFEW_ENFORCER_LOG"
chmod 666 "$CURFEW_ENFORCER_LOG" 2>/dev/null || true

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$CURFEW_ENFORCER_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$CURFEW_ENFORCER_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$CURFEW_ENFORCER_LOG.tmp"
        tail -n 500 "$CURFEW_ENFORCER_LOG" > "$tmp"
        mv "$tmp" "$CURFEW_ENFORCER_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "curfew_enforcer"; then
                echo "curfew_enforcer already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# ---- Time / activation (mirrors focus_daemon.sh::curfew_active) ----

_dec() {
    # Strip leading zeros so a zero-padded HHMM ("0500", "0830") is not parsed
    # as (sometimes invalid) octal by the shell's arithmetic. Keeps one digit.
    local n="$1"
    while [ "${n#0}" != "$n" ] && [ "${#n}" -gt 1 ]; do n="${n#0}"; done
    printf '%s' "$n"
}

is_curfew_now() {
    local now start end
    now="$(date +%H%M 2>/dev/null)"
    case "$now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now="$(_dec "$now")"; start="$(_dec "$NIGHT_CURFEW_START")"; end="$(_dec "$NIGHT_CURFEW_END")"
    if [ "$start" -le "$end" ]; then
        [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
    else
        [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
    fi
}

at_home() {
    [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE" 2>/dev/null)" = "focus" ]
}

# Whether this enforcer should be applying its restrictions right now.
should_act() {
    [ "${NIGHT_CURFEW_ENABLED:-0}" = "1" ] || return 1
    [ -e "$CURFEW_OVERRIDE_FILE" ] && return 1
    # Forced (test hook) bypasses both the clock and the home gate so the full
    # stack can be validated during the day from anywhere.
    [ -e "$CURFEW_FORCE_FILE" ] && return 0
    is_curfew_now && at_home
}

# ---- Layer 1: grayscale ----

apply_grayscale() {
    [ "${CURFEW_GRAYSCALE_ENABLED:-0}" = "1" ] || return 0
    settings put secure accessibility_display_daltonizer_enabled 1 2>/dev/null || true
    # Daltonizer "0" = full monochrome (grayscale).
    settings put secure accessibility_display_daltonizer 0 2>/dev/null || true
}

snapshot_grayscale() {
    local en lv
    en="$(settings get secure accessibility_display_daltonizer_enabled 2>/dev/null)"
    lv="$(settings get secure accessibility_display_daltonizer 2>/dev/null)"
    printf '%s\n%s\n' "${en:-0}" "${lv:-0}" > "$GRAYSCALE_SNAP" 2>/dev/null || true
}

restore_grayscale() {
    [ "${CURFEW_GRAYSCALE_ENABLED:-0}" = "1" ] || return 0
    local en lv
    if [ -f "$GRAYSCALE_SNAP" ]; then
        en="$(sed -n '1p' "$GRAYSCALE_SNAP")"
        lv="$(sed -n '2p' "$GRAYSCALE_SNAP")"
    fi
    # If the snapshot is missing or "null", default to disabled (the norm).
    case "$en" in ''|null) en=0 ;; esac
    case "$lv" in ''|null) lv=-1 ;; esac
    settings put secure accessibility_display_daltonizer_enabled "$en" 2>/dev/null || true
    [ "$lv" != "-1" ] && settings put secure accessibility_display_daltonizer "$lv" 2>/dev/null || true
}

# ---- Layer 2: Do-Not-Disturb (alarms only) ----

apply_dnd() {
    [ "${CURFEW_DND_ENABLED:-0}" = "1" ] || return 0
    # alarms-only lets the morning alarm ring but silences everything else.
    cmd notification set_dnd alarms >/dev/null 2>&1 || true
}

restore_dnd() {
    [ "${CURFEW_DND_ENABLED:-0}" = "1" ] || return 0
    cmd notification set_dnd off >/dev/null 2>&1 || true
}

# ---- Layer 3: per-UID network allow-list (default OFF) ----

# Resolve the UIDs of the night-whitelisted packages. Apps not installed are
# silently skipped. Output: one numeric UID per line.
night_uids() {
    local plist="$STATE_DIR/night_whitelist.txt"
    [ -f "$plist" ] || return 0
    # `pm list packages -U` lines look like: "package:com.foo uid:10123"
    local map="$STATE_DIR/uid_map.txt"
    pm list packages -U 2>/dev/null \
        | sed 's/^package://' > "$map"
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        awk -v p="$pkg" '$1 == p { sub(/uid:/,"",$2); print $2 }' "$map"
    done < "$plist"
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
        while IFS= read -r uid; do
            case "$uid" in ''|*[!0-9]*) continue ;; esac
            iptw "$ipt" -A "$CURFEW_NET_IPT_CHAIN" -m owner --uid-owner "$uid" -j ACCEPT 2>/dev/null || true
        done < "$CURFEW_NET_UID_CACHE"
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

# Set to 1 once the net chain has been built in this process. Used purely to
# tell an *anomalous* mid-curfew disappearance (something outside this script
# deleted the chain) apart from the legitimate first build on curfew entry.
# Because it is a process-local var, a fresh enforcer starts empty and never
# false-flags its own initial build.
NET_BUILT=""

# Refresh the cached UID list (one `pm list packages -U` fork). Called once per
# main tick so the fast watchdog can rebuild from the cache without forking.
refresh_uid_cache() {
    night_uids > "$CURFEW_NET_UID_CACHE.tmp" 2>/dev/null \
        && mv "$CURFEW_NET_UID_CACHE.tmp" "$CURFEW_NET_UID_CACHE" 2>/dev/null || true
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

# ---- Apply / revert orchestration ----

enter_curfew() {
    if [ ! -e "$CURFEW_ENFORCER_STATE" ]; then
        snapshot_grayscale
        : > "$CURFEW_ENFORCER_STATE"
        log "Curfew ON - locking grayscale${CURFEW_DND_ENABLED:+ + DND}${CURFEW_NET_ENABLED:+ + net}"
    fi
    # Re-apply every tick so manual toggles snap back.
    apply_grayscale
    apply_dnd
    apply_net
}

exit_curfew() {
    [ -e "$CURFEW_ENFORCER_STATE" ] || return 0
    restore_grayscale
    restore_dnd
    teardown_net
    NET_BUILT=""
    rm -f "$CURFEW_ENFORCER_STATE" "$CURFEW_NET_UID_CACHE"
    log "Curfew OFF - restored display/DND, tore down net chain"
}

cleanup() {
    # On a clean stop, leave the user back in daytime state.
    log "curfew_enforcer shutting down - reverting"
    exit_curfew
    rm -f "$PIDFILE"
    exit 0
}

trap cleanup INT TERM

main() {
    acquire_lock
    log "curfew_enforcer started (PID=$$, window=${NIGHT_CURFEW_START}-${NIGHT_CURFEW_END}, net=${CURFEW_NET_ENABLED})"
    local tick=0 act netstate rebuilds
    while true; do
        if should_act; then act=1; enter_curfew; else act=0; exit_curfew; fi
        # Heartbeat every ~6 ticks (~30s): proves the loop is alive even when it
        # is quietly re-applying. Without this, "alive but idle" and "dead" look
        # identical in the log, so process death can't be inferred from silence.
        tick=$((tick + 1))
        if [ "$((tick % 6))" -eq 0 ]; then
            if iptw iptables -L "$CURFEW_NET_IPT_CHAIN" >/dev/null 2>&1; then
                netstate=up
            else
                netstate=down
            fi
            log "heartbeat tick=$tick act=$act net=$netstate"
        fi
        rotate_log
        # While curfew is active with the net layer on, hold the chain pinned
        # against netd's table rewrites for the whole interval (fast watchdog),
        # instead of sleeping blind. Otherwise a plain sleep is enough.
        if [ "$act" = 1 ] && [ "${CURFEW_NET_ENABLED:-0}" = "1" ]; then
            rebuilds="$(net_hold "$CURFEW_ENFORCER_INTERVAL")"
            [ "${rebuilds:-0}" -gt 0 ] 2>/dev/null \
                && log "net watchdog re-pinned chain ${rebuilds}x in last ${CURFEW_ENFORCER_INTERVAL}s (netd flush)"
        else
            sleep "$CURFEW_ENFORCER_INTERVAL"
        fi
    done
}

main "$@"
