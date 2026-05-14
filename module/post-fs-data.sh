#!/system/bin/sh
# Runs early in boot - set up hosts file and start watchdog
# MODDIR is set by Magisk and points to this module's directory
GUARDIAN_DIR="${ANDROID_GUARDIAN_DIR:-/data/adb/android_guardian}"
WATCHDOG_SCRIPT="${ANDROID_GUARDIAN_WATCHDOG_SCRIPT:-$GUARDIAN_DIR/watchdog.sh}"
LOG_FILE="$GUARDIAN_DIR/guardian.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] post-fs-data: $*" >>"$LOG_FILE"
}

write_watchdog_script() {
cat >"$WATCHDOG_SCRIPT" <<'WATCHDOG'
#!/system/bin/sh
# Secondary watchdog - runs independently of module state
# Even if module is "disabled" in Magisk UI, this keeps running and undoes it
GUARDIAN_DIR="${ANDROID_GUARDIAN_DIR:-/data/adb/android_guardian}"
MODULE_DIR="${ANDROID_GUARDIAN_MODULE_DIR:-/data/adb/modules/android_guardian}"
LOG_FILE="$GUARDIAN_DIR/watchdog.log"
CONTROL_FILE="$GUARDIAN_DIR/control"
HOSTS_BACKUP="$GUARDIAN_DIR/hosts.backup"
MODULE_HOSTS="$MODULE_DIR/system/etc/hosts"
LOOP_SLEEP_SECONDS=3
HOSTS_CHECK_EVERY_TICKS=10

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE"
}

is_enabled() {
    if [ ! -f "$CONTROL_FILE" ]; then
        return 1
    fi

    IFS= read -r guardian_state < "$CONTROL_FILE" || guardian_state=""
    [ "$guardian_state" = "ENABLED" ]
}

protect_module_flags() {
    if [ -f "$MODULE_DIR/disable" ]; then
        log "ALERT: Module disable detected via Magisk UI - removing disable flag"
        rm -f "$MODULE_DIR/disable"
    fi

    if [ -f "$MODULE_DIR/remove" ]; then
        log "ALERT: Module removal detected via Magisk UI - removing remove flag"
        rm -f "$MODULE_DIR/remove"
    fi
}

protect_hosts() {
    if [ ! -f "$HOSTS_BACKUP" ] || [ ! -f "$MODULE_HOSTS" ]; then
        return
    fi

    if ! cmp -s "$MODULE_HOSTS" "$HOSTS_BACKUP"; then
        log "ALERT: Hosts tampering detected - restoring"
        cp "$HOSTS_BACKUP" "$MODULE_HOSTS"
    fi
}

log "=== Watchdog starting ==="

tick_count=0
while true; do
    protect_module_flags

    if is_enabled; then
        if [ $((tick_count % HOSTS_CHECK_EVERY_TICKS)) -eq 0 ]; then
            protect_hosts
        fi
    fi

    tick_count=$((tick_count + 1))
    sleep "$LOOP_SLEEP_SECONDS"
done
WATCHDOG
}

start_watchdog() {
    nohup sh "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
}

post_fs_main() {
    mkdir -p "$GUARDIAN_DIR"
    log "Guardian module loading"
    write_watchdog_script
    chmod 755 "$WATCHDOG_SCRIPT"

    if [ "${ANDROID_GUARDIAN_POST_FS_SKIP_WATCHDOG_START:-0}" -ne 1 ]; then
        start_watchdog
        log "Watchdog started"
        return
    fi

    log "Watchdog generation complete (start skipped)"
}

if [ "${ANDROID_GUARDIAN_POST_FS_SKIP_MAIN:-0}" -ne 1 ]; then
    post_fs_main
fi
