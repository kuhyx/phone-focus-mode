#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Launcher enforcer for rooted Android.
#
# Goal:
#   1. Keep $LAUNCHER_PACKAGE installed at all times. If it is
#      uninstalled (with or without `-k`), reinstall from
#      $LAUNCHER_APK snapshot within $LAUNCHER_CHECK_INTERVAL.
#   2. Keep it pinned as the default HOME activity. If the user
#      switches launchers via Settings or the picker, restore it.
#   3. Prevent competing launchers ($LAUNCHER_COMPETITORS) from
#      being offered by `pm disable-user`-ing them.
#
# Known limitation: a user with root in a terminal can still
# stop this daemon and change HOME. That's the same threat model
# as hosts_enforcer.sh - this closes the "tap to uninstall / pick
# a new launcher" gap and leaves a tamper trail in the log.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/launcher_enforcer.pid"
# Tracks competitors we disabled ourselves, so `launcher-stop` can undo them.
DISABLED_COMPETITORS_FILE="$STATE_DIR/disabled_competitors.txt"

mkdir -p "$STATE_DIR" "$(dirname "$LAUNCHER_APK")"
touch "$LAUNCHER_LOG" "$DISABLED_COMPETITORS_FILE"
chmod 666 "$LAUNCHER_LOG" "$DISABLED_COMPETITORS_FILE" 2>/dev/null || true

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$LAUNCHER_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$LAUNCHER_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$LAUNCHER_LOG.tmp"
        tail -n 500 "$LAUNCHER_LOG" > "$tmp"
        mv "$tmp" "$LAUNCHER_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "launcher_enforcer"; then
                echo "launcher_enforcer already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# ---- Package state helpers ----

pkg_installed() {
    # `pm path` exits 0 and prints package: line when present.
    pm path "$1" >/dev/null 2>&1
}

pkg_enabled() {
    # `pm list packages -e` lists enabled packages. Use exact match.
    pm list packages -e 2>/dev/null | grep -qxE "package:$1"
}

current_home_component() {
    # Returns "pkg/Activity" of the current default HOME, or "" if ambiguous.
    cmd package resolve-activity --brief -c android.intent.category.HOME \
            -a android.intent.action.MAIN 2>/dev/null \
        | awk 'NR==2{print}'
}

# ---- Enforcement actions ----

reinstall_launcher() {
    if [ ! -f "$LAUNCHER_APK" ]; then
        log "ERROR: cannot reinstall - APK snapshot missing at $LAUNCHER_APK"
        return 1
    fi
    local expected actual
    expected="$(cat "$LAUNCHER_SHA_FILE" 2>/dev/null)"
    actual="$(sha256sum "$LAUNCHER_APK" 2>/dev/null | awk '{print $1}')"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
        log "ERROR: APK snapshot hash mismatch (expected $expected, got $actual) - refusing to install"
        return 1
    fi
    log "REINSTALL: $LAUNCHER_PACKAGE missing - installing from snapshot"
    # -g grants all runtime permissions so the launcher starts clean
    # without blocking on a permission dialog that itself may need the
    # launcher to be usable.
    if pm install -r -g "$LAUNCHER_APK" >/dev/null 2>&1; then
        log "REINSTALL: $LAUNCHER_PACKAGE installed successfully"
        return 0
    fi
    # Fallback: `pm install` without -g on older Androids
    if pm install -r "$LAUNCHER_APK" >/dev/null 2>&1; then
        log "REINSTALL: $LAUNCHER_PACKAGE installed (without -g)"
        return 0
    fi
    log "ERROR: pm install failed"
    return 1
}

ensure_home_pinned() {
    local desired actual
    desired="$(cat "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null)"
    if [ -z "$desired" ]; then
        return 0  # not armed yet; deploy.sh --snapshot-launcher writes this
    fi
    actual="$(current_home_component)"
    if [ "$actual" = "$desired" ]; then
        return 0
    fi
    log "HOME: default is '$actual' not '$desired' - restoring"
    cmd package set-home-activity "$desired" >/dev/null 2>&1 || \
        log "ERROR: set-home-activity failed for $desired"
}

disable_competitors() {
    # Disable every competitor that is still enabled. Remember what we
    # disabled so `launcher-stop` can re-enable.
    echo "$LAUNCHER_COMPETITORS" | while read -r pkg; do
        [ -z "$pkg" ] && continue
        [ "${pkg#\#}" != "$pkg" ] && continue  # skip comments
        if pkg_installed "$pkg" && pkg_enabled "$pkg"; then
            if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
                log "Disabled competing launcher: $pkg"
                grep -qxE "$pkg" "$DISABLED_COMPETITORS_FILE" 2>/dev/null \
                    || echo "$pkg" >> "$DISABLED_COMPETITORS_FILE"
            fi
        fi
    done
}

# ---- Main loop ----

cleanup() {
    log "launcher_enforcer shutting down"
    rm -f "$PIDFILE"
    exit 0
}

trap cleanup INT TERM

main() {
    acquire_lock
    log "launcher_enforcer started (PID=$$)"

    # Initial arm-up
    if ! pkg_installed "$LAUNCHER_PACKAGE"; then
        reinstall_launcher || true
    fi
    ensure_home_pinned
    disable_competitors

    while true; do
        if ! pkg_installed "$LAUNCHER_PACKAGE"; then
            reinstall_launcher || true
        fi
        ensure_home_pinned
        disable_competitors
        rotate_log
        sleep "$LAUNCHER_CHECK_INTERVAL"
    done
}

main "$@"
