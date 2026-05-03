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

# ---- Workout-aware canonical selection ----
# When workout_detector.sh writes "1" to $WORKOUT_ACTIVE_FILE, switch to
# the YouTube-relaxed canonical. Any other value (including missing file or
# unreadable) falls back to the full-block canonical (fail-closed).
workout_active() {
    [ -f "$WORKOUT_ACTIVE_FILE" ] || return 1
    local v
    v="$(cat "$WORKOUT_ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')"
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

is_bind_mounted_correctly() {
    # Android devices often already have /system/etc/hosts as its own mount
    # point (OEM overlay / f2fs block). A mere "path is in /proc/self/mounts"
    # check is not enough - we must verify the mounted content matches our
    # currently-active canonical by hash (which depends on workout state).
    if [ ! -f "$HOSTS_TARGET" ]; then
        return 1
    fi
    local target_hash canonical_hash canonical
    canonical="$(current_canonical)"
    target_hash="$(sha256_of "$HOSTS_TARGET")"
    canonical_hash="$(sha256_of "$canonical")"
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
    local system_mount canonical
    canonical="$(current_canonical)"
    system_mount="$(awk '$2=="/system"{print $2; exit}' /proc/self/mounts)"
    if [ -z "$system_mount" ]; then
        system_mount="/system"
    fi
    mount -o remount,rw "$system_mount" 2>/dev/null || true
    chattr -i "$HOSTS_TARGET" 2>/dev/null || true
    cp "$canonical" "$HOSTS_TARGET" 2>/dev/null || true
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
    local canonical
    canonical="$(current_canonical)"
    # Try plain bind mount - no remount-rw of /system needed.
    if mount --bind "$canonical" "$HOSTS_TARGET" 2>/dev/null; then
        mount -o remount,ro,bind "$HOSTS_TARGET" 2>/dev/null || true
        if is_bind_mounted_correctly; then
            log "Bind-mounted $canonical over $HOSTS_TARGET"
            sync_magisk_module "$canonical"
            return 0
        fi
        log "Bind mount reported success but target still mismatches - unmounting"
        umount "$HOSTS_TARGET" 2>/dev/null || true
    fi
    # Bind failed - fall back to direct overwrite of /system/etc/hosts.
    log "Bind mount failed - falling back to direct overwrite"
    make_target_writable_once
    if is_bind_mounted_correctly; then
        sync_magisk_module "$canonical"
        return 0
    fi
    return 1
}

# Keep the Magisk Systemless Hosts module file in sync with the currently
# active canonical so that a future reboot mounts the correct variant. We
# only rewrite when the contents differ (cheap hash compare) to avoid
# touching the module dir on every loop iteration.
sync_magisk_module() {
    local canonical="$1"
    [ -n "$canonical" ] && [ -f "$canonical" ] || return 0
    [ -d "$(dirname "$HOSTS_MAGISK_MODULE_FILE")" ] || return 0
    local module_hash canonical_hash
    module_hash="$(sha256_of "$HOSTS_MAGISK_MODULE_FILE")"
    canonical_hash="$(sha256_of "$canonical")"
    if [ "$module_hash" != "$canonical_hash" ]; then
        cp "$canonical" "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || return 0
        chmod 644 "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || true
        log "Synced Magisk module hosts to $(basename "$canonical")"
    fi
}

ensure_canonical_immutable() {
    # Lock both canonical variants — whichever is currently active and the
    # other one (so a future workout transition is just as tamper-resistant).
    chmod 644 "$HOSTS_CANONICAL" 2>/dev/null || true
    chattr +i "$HOSTS_CANONICAL" 2>/dev/null || true
    if [ -f "$HOSTS_CANONICAL_WORKOUT" ]; then
        chmod 644 "$HOSTS_CANONICAL_WORKOUT" 2>/dev/null || true
        chattr +i "$HOSTS_CANONICAL_WORKOUT" 2>/dev/null || true
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
        rotate_log
        sleep "$HOSTS_CHECK_INTERVAL"
    done
}

main "$@"
