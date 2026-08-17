#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Hosts file enforcer for rooted Android.
#
# Mirrors the PC-side guard in linux_configuration/hosts/ but
# for /system/etc/hosts on Android, which has no chattr, no
# systemd, and where /system is read-only.
#
# Strategy (defense in depth):
#   1. Canonical hosts file lives at HOSTS_CANONICAL and is
#      chattr +i (best-effort; ignored if kernel/fs rejects).
#   2. Bind-mount HOSTS_CANONICAL read-only over HOSTS_TARGET so
#      that even `echo > /system/etc/hosts` fails for everyone,
#      including root-in-a-terminal-app, without re-mounting.
#   3. A watchdog loop re-asserts the bind mount and verifies
#      sha256 every HOSTS_CHECK_INTERVAL seconds.
#
# Known limitation: a user with root *and* willingness to run
# `umount /system/etc/hosts; mount -o remount,rw /system ...`
# can still bypass this. Making it "impossible without USB" is
# not achievable on a rooted phone with a local terminal.
# This enforcer closes the one-liner gap and adds logging so
# tampering leaves an audit trail.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
# shellcheck source=hosts_magisk.sh
. "$SCRIPT_DIR/hosts_magisk.sh"
# shellcheck source=hosts_mount.sh
. "$SCRIPT_DIR/hosts_mount.sh"

PIDFILE="$STATE_DIR/hosts_enforcer.pid"

mkdir -p "$STATE_DIR" "$(dirname "$HOSTS_CANONICAL")"
touch "$HOSTS_LOG"
chmod 666 "$HOSTS_LOG" 2>/dev/null || true

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$HOSTS_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$HOSTS_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$HOSTS_LOG.tmp"
        tail -n 500 "$HOSTS_LOG" > "$tmp"
        mv "$tmp" "$HOSTS_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "hosts_enforcer"; then
                echo "hosts_enforcer already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

sha256_of() {
    # Android's toybox has sha256sum; fall back to md5sum if missing.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        md5sum "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# ---- Workout-aware canonical selection ----
# When workout_detector.sh writes "1" to $WORKOUT_ACTIVE_FILE, switch to
# the YouTube-relaxed canonical. Any other value (including missing file or
# unreadable) falls back to the full-block canonical (fail-closed).
workout_active() {
    [ -f "$WORKOUT_ACTIVE_FILE" ] || return 1
    local v
    v="$(tr -d '[:space:]' < "$WORKOUT_ACTIVE_FILE" 2>/dev/null)"
    [ "$v" = "1" ]
}

current_canonical() {
    if workout_active && [ -f "$HOSTS_CANONICAL_WORKOUT" ]; then
        echo "$HOSTS_CANONICAL_WORKOUT"
    else
        echo "$HOSTS_CANONICAL"
    fi
}

current_sha_file() {
    if workout_active && [ -f "$HOSTS_SHA_FILE_WORKOUT" ]; then
        echo "$HOSTS_SHA_FILE_WORKOUT"
    else
        echo "$HOSTS_SHA_FILE"
    fi
}











verify_and_restore() {
    local canonical sha_file
    canonical="$(current_canonical)"
    sha_file="$(current_sha_file)"

    if [ ! -f "$canonical" ]; then
        log "ERROR: canonical hosts missing at $canonical"
        return 1
    fi

    local expected
    expected="$(cat "$sha_file" 2>/dev/null)"
    if [ -z "$expected" ]; then
        expected="$(sha256_of "$canonical")"
        echo "$expected" > "$sha_file"
        chmod 644 "$sha_file" 2>/dev/null || true
        chattr +i "$sha_file" 2>/dev/null || true
    fi

    # Canonical integrity check
    local actual_canonical
    actual_canonical="$(sha256_of "$canonical")"
    if [ "$actual_canonical" != "$expected" ]; then
        log "TAMPER: $(basename "$canonical") hash mismatch (expected $expected, got $actual_canonical)"
        # We cannot fix the canonical from here - it is the source of truth.
        # Just log and continue; deploy.sh must re-push.
        return 1
    fi

    # Live target integrity check. Mismatch can mean either tampering OR a
    # legitimate workout-state transition that swapped the active canonical.
    # In both cases the fix is the same: re-assert the bind mount with the
    # currently-active canonical.
    local actual_target
    actual_target="$(sha256_of "$HOSTS_TARGET")"
    if [ "$actual_target" != "$expected" ]; then
        if workout_active; then
            log "Workout-active swap: $HOSTS_TARGET differs from workout canonical - re-mounting"
        else
            log "TAMPER or post-workout swap: $HOSTS_TARGET hash mismatch - restoring"
        fi
        assert_bind_mount
        flush_browser_dns_caches
    fi
}

cleanup() {
    log "hosts_enforcer shutting down"
    rm -f "$PIDFILE"
    exit 0
}

trap cleanup INT TERM

main() {
    acquire_lock
    log "hosts_enforcer started (PID=$$)"

    ensure_canonical_immutable
    protect_magisk_module
    # Initial assertion
    assert_bind_mount || true
    # Restart netd so its in-memory hosts cache picks up the bind mount.
    # Android 13 caches /etc/hosts at netd startup and never re-reads it;
    # without this restart every DNS query bypasses our block list.
    restart_netd_for_hosts_cache
    flush_browser_dns_caches

    # Seed sha files if missing — one per canonical variant.
    if [ ! -f "$HOSTS_SHA_FILE" ] && [ -f "$HOSTS_CANONICAL" ]; then
        sha256_of "$HOSTS_CANONICAL" > "$HOSTS_SHA_FILE"
        chmod 644 "$HOSTS_SHA_FILE" 2>/dev/null || true
        chattr +i "$HOSTS_SHA_FILE" 2>/dev/null || true
    fi
    if [ ! -f "$HOSTS_SHA_FILE_WORKOUT" ] && [ -f "$HOSTS_CANONICAL_WORKOUT" ]; then
        sha256_of "$HOSTS_CANONICAL_WORKOUT" > "$HOSTS_SHA_FILE_WORKOUT"
        chmod 644 "$HOSTS_SHA_FILE_WORKOUT" 2>/dev/null || true
        chattr +i "$HOSTS_SHA_FILE_WORKOUT" 2>/dev/null || true
    fi

    while true; do
        verify_and_restore
        protect_magisk_module
        rotate_log
        sleep "$HOSTS_CHECK_INTERVAL"
    done
}

main "$@"
