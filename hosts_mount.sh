#!/system/bin/sh
# shellcheck shell=ash
# hosts_mount.sh — the bind-mount half of hosts_enforcer.sh: proving the
# blocklist is actually mounted over $HOSTS_TARGET, clearing a stale or wrong
# mount, and making the target writable once on ROMs that ship it read-only.
#
# A flat sibling, not lib/, for the same reason as hosts_magisk.sh: deploy.sh
# pushes phone scripts into one directory.
#
# Sourced by hosts_enforcer.sh, which owns log() and $HOSTS_TARGET, the only
# config.sh global these read. Nothing is assigned here.

is_bind_mounted_correctly() {
    # Android devices often already have /system/etc/hosts as its own mount
    # point (OEM overlay / f2fs block). A mere "path is in /proc/self/mounts"
    # check is not enough - we must verify the mounted content matches our
    # currently-active canonical by hash (which depends on workout state).
    # No early -f guard on the target: sha256_of returns empty for a file
    # that does not exist, so the -n check below already rejects that case.
    # The guard was provably equivalent — a mutation removing it could not be
    # distinguished by any test — and equivalent code is a claim of a check
    # that is not actually being made.
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
