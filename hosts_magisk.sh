#!/system/bin/sh
# shellcheck shell=ash
# hosts_magisk.sh — the persistence and cache-invalidation half of
# hosts_enforcer.sh: keeping the Magisk systemless-hosts module in step with
# the canonical blocklist, holding the canonical file immutable, and making
# already-running resolvers notice a change (Firefox DoH, browser DNS caches,
# netd).
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory,
# which is why dns_iptables.sh, tether_iptables.sh and curfew_net.sh live
# beside their enforcers too.
#
# Sourced by hosts_enforcer.sh, which owns log() and the config.sh globals
# these read ($HOSTS_MAGISK_MODULE_FILE, $HOSTS_CANONICAL,
# $HOSTS_CANONICAL_WORKOUT, $BROWSER_PACKAGES, $STATE_DIR). Nothing is
# assigned here, so there is no global to keep in step.

# Keep the Magisk Systemless Hosts module file in sync with the currently
# active canonical so that a future reboot mounts the correct variant. We
# only rewrite when the contents differ (cheap hash compare) to avoid
# touching the module dir on every loop iteration.
sync_magisk_module() {
    local canonical="$1"
    [ -n "$canonical" ] && [ -f "$canonical" ] || return 0
    local module_dir
    module_dir="$(dirname "$(dirname "$(dirname "$HOSTS_MAGISK_MODULE_FILE")")")"
    [ -d "$module_dir" ] || return 0
    local module_hash canonical_hash
    module_hash="$(sha256_of "$HOSTS_MAGISK_MODULE_FILE")"
    canonical_hash="$(sha256_of "$canonical")"
    if [ "$module_hash" != "$canonical_hash" ]; then
        # Drop +i on the module dir + file long enough to update, then re-lock.
        chattr -i "$module_dir" 2>/dev/null || true
        chattr -i "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || true
        cp "$canonical" "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || return 0
        chmod 644 "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || true
        chattr +i "$HOSTS_MAGISK_MODULE_FILE" 2>/dev/null || true
        log "Synced Magisk module hosts to $(basename "$canonical")"
    fi
    # Always re-assert dir-level lock at the end so a partial earlier failure
    # leaves us in the locked state on the next iteration.
    protect_magisk_module
}

# Defense against the user disabling the Magisk Systemless Hosts module via
# the Magisk app UI. The "Disable" / "Remove" buttons work by creating a
# marker file inside the module directory:
#
#     /data/adb/modules/hosts/disable      # disable on next reboot
#     /data/adb/modules/hosts/remove       # uninstall on next reboot
#
# We do TWO things every poll cycle:
#   1. Delete those markers if they appeared (so a reboot still loads us)
#   2. Set chattr +i on the module directory itself so the Magisk app cannot
#      create those markers in the first place. The +i flag on a directory
#      blocks adding/removing/renaming entries inside it, which is exactly
#      what `touch disable` does. Files already inside remain mutable, so
#      sync_magisk_module() can still rewrite the hosts file (it briefly
#      drops the lock above to handle the rare case where it must).
#
# To intentionally disable the module for maintenance, run from a root
# shell on the phone:
#     focus_ctl.sh hosts-stop
#     chattr -i /data/adb/modules/hosts
#     touch /data/adb/modules/hosts/disable
protect_magisk_module() {
    local module_dir
    module_dir="$(dirname "$(dirname "$(dirname "$HOSTS_MAGISK_MODULE_FILE")")")"
    [ -d "$module_dir" ] || return 0
    # Step 1: nuke any disable/remove markers that may have been created
    # since the last poll. We have to chattr -i first because either of the
    # two locks below may already be in effect.
    local removed=0
    for marker in disable remove update; do
        local f="$module_dir/$marker"
        if [ -e "$f" ]; then
            chattr -i "$module_dir" 2>/dev/null || true
            chattr -i "$f" 2>/dev/null || true
            if rm -f "$f" 2>/dev/null; then
                removed=$((removed + 1))
                log "TAMPER: removed Magisk module marker $f"
            fi
        fi
    done
    # Step 2: re-lock the module dir so the Magisk app cannot recreate them
    # via its UI. Best-effort - if the kernel/fs rejects +i, the runtime
    # delete loop above is still our safety net.
    chattr +i "$module_dir" 2>/dev/null || true
    return $removed
}

# Write user.js to every Firefox profile to hard-disable DNS-over-HTTPS.
# Firefox uses hardcoded Cloudflare bootstrap IPs (104.16.248.249 etc.) to
# reach mozilla.cloudflare-dns.com, bypassing /etc/hosts entirely.
# TRR mode 5 = DoH disabled; the pref is re-applied on every flush so it
# survives Firefox's automatic pref-reset logic.
disable_firefox_doh() {
    local profile_dir
    for profile_dir in /data/data/org.mozilla.fenix/files/mozilla/*/; do
        # Only write to real profile directories (they contain prefs.js).
        [ -f "${profile_dir}prefs.js" ] || continue
        grep -qF '"network.trr.mode"' "${profile_dir}user.js" 2>/dev/null \
            || { printf 'user_pref("network.trr.mode", 5);\n' >> "${profile_dir}user.js" 2>/dev/null \
                     && log "Wrote DoH-disable pref to ${profile_dir}user.js"; }
    done
}

# Force-stop browsers so their in-process DNS caches are cleared.
# Apps like Firefox and Chrome cache resolved IPs internally; without
# a fresh start they continue reaching blocked domains despite hosts.
# Called at daemon startup and after every detected restore/tamper.
flush_browser_dns_caches() {
    local pkg
    for pkg in $BROWSER_PACKAGES; do
        [ -n "$pkg" ] || continue
        if am force-stop "$pkg" 2>/dev/null; then
            log "Flushed DNS cache: force-stopped $pkg"
        fi
    done
    disable_firefox_doh
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

# Restart netd so it re-reads the bind-mounted hosts file from disk.
# Android 13's DNS resolver (libnetd_resolv.so) caches /etc/hosts entirely
# in memory when netd starts. Our bind mount updates the on-disk file but
# netd's in-memory cache stays stale until netd restarts.
#
# We use a PID-stamp file: if netd's PID hasn't changed since our last
# restart, we already restarted it in this boot session and skip the work.
# This avoids a network blip on every enforcer restart, while still
# triggering a reload if netd itself has been cycled.
restart_netd_for_hosts_cache() {
    local stamp_file="$STATE_DIR/netd_restart.pid"
    local current_pid
    current_pid="$(pgrep -x netd 2>/dev/null | head -1 || true)"
    [ -n "$current_pid" ] || return 0

    local last_pid=""
    [ -f "$stamp_file" ] && last_pid="$(cat "$stamp_file" 2>/dev/null)"

    if [ "$current_pid" = "$last_pid" ]; then
        # Already restarted netd for this incarnation — nothing to do.
        return 0
    fi

    log "Restarting netd (PID $current_pid) to reload hosts file cache (~3s network pause)..."
    stop netd 2>/dev/null || true
    sleep 2
    start netd 2>/dev/null || true
    sleep 2
    local new_pid
    new_pid="$(pgrep -x netd 2>/dev/null | head -1 || true)"
    echo "${new_pid:-$current_pid}" > "$stamp_file" 2>/dev/null || true
    log "netd restarted (new PID ${new_pid:-unknown}) — hosts cache is now live"
}
