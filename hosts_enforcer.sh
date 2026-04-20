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
            cmdline="$(cat "/proc/$old_pid/cmdline" 2>/dev/null | tr '\0' ' ')"
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

is_bind_mounted_correctly() {
    # Android devices often already have /system/etc/hosts as its own mount
    # point (OEM overlay / f2fs block). A mere "path is in /proc/self/mounts"
    # check is not enough - we must verify the mounted content matches our
    # canonical by hash. Otherwise we'd accept OEM mounts as our own.
    if [ ! -f "$HOSTS_TARGET" ]; then
        return 1
    fi
    local target_hash canonical_hash
    target_hash="$(sha256_of "$HOSTS_TARGET")"
    canonical_hash="$(sha256_of "$HOSTS_CANONICAL")"
    [ -n "$target_hash" ] && [ "$target_hash" = "$canonical_hash" ]
}

unmount_existing_hosts_mount() {
    # If anything else is already mounted on /system/etc/hosts (OEM overlay
    # or a previous failed bind), unmount it so we can take its place.
    local attempts=0
    while grep -qE "[[:space:]]${HOSTS_TARGET}[[:space:]]" /proc/self/mounts 2>/dev/null; do
        if [ "$attempts" -ge 5 ]; then
            log "Could not fully unmount $HOSTS_TARGET after 5 attempts"
            return 1
        fi
        umount "$HOSTS_TARGET" 2>/dev/null \
            || umount -l "$HOSTS_TARGET" 2>/dev/null \
            || break
        attempts=$((attempts + 1))
    done
    return 0
}

make_target_writable_once() {
    # /system is usually mounted read-only. Make it rw just long enough
    # to overwrite HOSTS_TARGET with the canonical content, then remount ro.
    local system_mount
    system_mount="$(awk '$2=="/system"{print $2; exit}' /proc/self/mounts)"
    if [ -z "$system_mount" ]; then
        system_mount="/system"
    fi
    mount -o remount,rw "$system_mount" 2>/dev/null || true
    chattr -i "$HOSTS_TARGET" 2>/dev/null || true
    cp "$HOSTS_CANONICAL" "$HOSTS_TARGET" 2>/dev/null || true
    chmod 644 "$HOSTS_TARGET" 2>/dev/null || true
    chattr +i "$HOSTS_TARGET" 2>/dev/null || true
    mount -o remount,ro "$system_mount" 2>/dev/null || true
}

assert_bind_mount() {
    if is_bind_mounted_correctly; then
        return 0
    fi
    # Something is in the way (OEM overlay or previous partial mount).
    unmount_existing_hosts_mount
    # Try plain bind mount - no remount-rw of /system needed.
    if mount --bind "$HOSTS_CANONICAL" "$HOSTS_TARGET" 2>/dev/null; then
        mount -o remount,ro,bind "$HOSTS_TARGET" 2>/dev/null || true
        if is_bind_mounted_correctly; then
            log "Bind-mounted $HOSTS_CANONICAL over $HOSTS_TARGET"
            return 0
        fi
        log "Bind mount reported success but target still mismatches - unmounting"
        umount "$HOSTS_TARGET" 2>/dev/null || true
    fi
    # Bind failed - fall back to direct overwrite of /system/etc/hosts.
    log "Bind mount failed - falling back to direct overwrite"
    make_target_writable_once
    if is_bind_mounted_correctly; then
        return 0
    fi
    return 1
}

ensure_canonical_immutable() {
    chmod 644 "$HOSTS_CANONICAL" 2>/dev/null || true
    chattr +i "$HOSTS_CANONICAL" 2>/dev/null || true
}

verify_and_restore() {
    if [ ! -f "$HOSTS_CANONICAL" ]; then
        log "ERROR: canonical hosts missing at $HOSTS_CANONICAL"
        return 1
    fi

    local expected
    expected="$(cat "$HOSTS_SHA_FILE" 2>/dev/null)"
    if [ -z "$expected" ]; then
        expected="$(sha256_of "$HOSTS_CANONICAL")"
        echo "$expected" > "$HOSTS_SHA_FILE"
        chmod 644 "$HOSTS_SHA_FILE" 2>/dev/null || true
        chattr +i "$HOSTS_SHA_FILE" 2>/dev/null || true
    fi

    # Canonical integrity check
    local actual_canonical
    actual_canonical="$(sha256_of "$HOSTS_CANONICAL")"
    if [ "$actual_canonical" != "$expected" ]; then
        log "TAMPER: canonical hash mismatch (expected $expected, got $actual_canonical)"
        # We cannot fix the canonical from here - it is the source of truth.
        # Just log and continue; deploy.sh must re-push.
        return 1
    fi

    # Live target integrity check
    local actual_target
    actual_target="$(sha256_of "$HOSTS_TARGET")"
    if [ "$actual_target" != "$expected" ]; then
        log "TAMPER: $HOSTS_TARGET hash mismatch - restoring"
        assert_bind_mount
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
    # Initial assertion
    assert_bind_mount || true

    # Seed sha file if missing
    if [ ! -f "$HOSTS_SHA_FILE" ]; then
        sha256_of "$HOSTS_CANONICAL" > "$HOSTS_SHA_FILE"
        chmod 644 "$HOSTS_SHA_FILE" 2>/dev/null || true
        chattr +i "$HOSTS_SHA_FILE" 2>/dev/null || true
    fi

    while true; do
        verify_and_restore
        rotate_log
        sleep "$HOSTS_CHECK_INTERVAL"
    done
}

main "$@"
