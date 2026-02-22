#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Focus Mode Control Utility
# Run on the phone via: su -c /data/local/tmp/focus_mode/focus_ctl.sh <command>
# Or from PC via: adb shell su -c '/data/local/tmp/focus_mode/focus_ctl.sh <command>'
# ============================================================

SCRIPT_DIR="/data/local/tmp/focus_mode"
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/daemon.pid"

# ---- Logging ----
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$LOG_FILE"
}

usage() {
    echo "Usage: focus_ctl.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start      - Start the focus mode daemon"
    echo "  stop       - Stop the daemon and re-enable all apps"
    echo "  status     - Show current mode, location and disabled apps"
    echo "  enable     - Force focus mode on (regardless of location)"
    echo "  disable    - Force focus mode off (regardless of location)"
    echo "  log        - Show daemon log"
    echo "  list-apps  - List all non-whitelisted third-party apps"
    echo "  whitelist  - List currently whitelisted packages"
    echo "  restart    - Restart the daemon"
    echo ""
}

# Helper to check if daemon is running
daemon_pid() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid="$(cat "$PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
        fi
    fi
}

cmd_start() {
    local pid
    pid="$(daemon_pid)"
    if [ -n "$pid" ]; then
        echo "Daemon already running (PID $pid)"
        return
    fi
    setsid sh "$SCRIPT_DIR/focus_daemon.sh" </dev/null >/dev/null 2>&1 &
    sleep 2
    pid="$(daemon_pid)"
    if [ -n "$pid" ]; then
        echo "Daemon started (PID $pid)"
    else
        echo "ERROR: Daemon failed to start. Check log: $LOG_FILE"
    fi
}

cmd_stop() {
    local pid
    pid="$(daemon_pid)"
    if [ -z "$pid" ]; then
        echo "Daemon not running"
        # Clean up stale pidfile if present
        rm -f "$PIDFILE"
    else
        kill -TERM "$pid"
        echo "Daemon stopped (sent SIGTERM to PID $pid)"
    fi
}

cmd_status() {
    local pid
    pid="$(daemon_pid)"
    local mode="unknown"
    [ -f "$MODE_FILE" ] && mode="$(cat "$MODE_FILE")"

    echo "=== Focus Mode Status ==="
    if [ -n "$pid" ]; then
        echo "Daemon:   RUNNING (PID $pid)"
    else
        echo "Daemon:   STOPPED"
    fi
    echo "Mode:     $mode"
    echo "Home:     $HOME_LAT, $HOME_LON (radius: ${RADIUS}m)"
    echo ""

    # Show current location if available
    location="$(dumpsys location 2>/dev/null \
        | grep -oE 'Location\[.*[-]?[0-9]{1,3}\.[0-9]+,[-]?[0-9]{1,3}\.[0-9]+' \
        | grep -oE '[-]?[0-9]{1,3}\.[0-9]+,[-]?[0-9]{1,3}\.[0-9]+' \
        | head -1)"

    if [ -n "$location" ]; then
        lat="$(echo "$location" | cut -d',' -f1)"
        lon="$(echo "$location" | cut -d',' -f2)"
        dist="$(echo "$lat $lon $HOME_LAT $HOME_LON" | awk '{
            PI=3.14159265358979; R=6371000
            a1=$1*PI/180; o1=$2*PI/180
            a2=$3*PI/180; o2=$4*PI/180
            da=a2-a1; dlon=o2-o1
            x=sin(da/2)^2+cos(a1)*cos(a2)*sin(dlon/2)^2
            printf "%d", R*2*atan2(sqrt(x),sqrt(1-x))
        }')"
        echo "Location: $lat, $lon"
        echo "Distance: ${dist}m from home"
    else
        echo "Location: unavailable"
    fi

    echo ""
    if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
        echo "=== Apps disabled by focus mode ==="
        cat "$DISABLED_APPS_FILE"
    else
        echo "No apps currently disabled by focus mode"
    fi
}

cmd_enable() {
    # Disable daemon temporarily, force focus
    echo "Forcing focus mode ON..."
    . "$SCRIPT_DIR/config.sh"

    # Source common functions - inline here for standalone use
    : > "$STATE_DIR/disabled_by_focus.txt"
    local count=0
    for pkg in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
        # Check whitelist
        whitelisted=0
        for w in $WHITELIST; do
            w_clean="$(echo "$w" | tr -d '[:space:]')"
            [ -z "$w_clean" ] && continue
            [ "$pkg" = "$w_clean" ] && { whitelisted=1; break; }
        done
        [ "$whitelisted" -eq 1 ] && continue

        # Check system protection
        protected=0
        for prefix in $SYSTEM_NEVER_DISABLE; do
            prefix_clean="$(echo "$prefix" | tr -d '[:space:]')"
            [ -z "$prefix_clean" ] && continue
            case "$pkg" in
                "$prefix_clean"*) protected=1; break ;;
            esac
        done
        [ "$protected" -eq 1 ] && continue

        if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >> "$STATE_DIR/disabled_by_focus.txt"
            count=$((count + 1))
        fi
    done
    echo "focus" > "$MODE_FILE"
    echo "Done: disabled $count apps"
}

cmd_disable() {
    echo "Forcing focus mode OFF..."
    if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
        local count=0
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            pm enable "$pkg" >/dev/null 2>&1 && count=$((count + 1))
        done < "$DISABLED_APPS_FILE"
        : > "$DISABLED_APPS_FILE"
        echo "Done: re-enabled $count apps"
    else
        echo "No apps to re-enable"
    fi
    echo "normal" > "$MODE_FILE"
}

cmd_log() {
    local lines="${1:-50}"
    if [ -f "$LOG_FILE" ]; then
        tail -n "$lines" "$LOG_FILE"
    else
        echo "Log file not found: $LOG_FILE"
    fi
}

cmd_list_apps() {
    echo "=== Third-party apps NOT in whitelist ==="
    for pkg in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
        whitelisted=0
        for w in $WHITELIST; do
            w="$(echo "$w" | tr -d '[:space:]')"
            [ -z "$w" ] && continue
            [ "$pkg" = "$w" ] && { whitelisted=1; break; }
        done
        if [ "$whitelisted" -eq 0 ]; then
            # Check if currently disabled by focus mode
            if grep -qF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null; then
                echo "  [BLOCKED] $pkg"
            else
                echo "  [active]  $pkg"
            fi
        fi
    done
    echo ""
    echo "=== Whitelisted apps ==="
    for w in $WHITELIST; do
        w="$(echo "$w" | tr -d '[:space:]')"
        [ -z "$w" ] && continue
        echo "  [allowed] $w"
    done
}

cmd_whitelist() {
    echo "=== Whitelisted packages ==="
    for w in $WHITELIST; do
        w="$(echo "$w" | tr -d '[:space:]')"
        [ -z "$w" ] && continue
        # Check if installed
        if pm list packages "$w" 2>/dev/null | grep -qF "$w"; then
            echo "  [installed] $w"
        else
            echo "  [not found] $w"
        fi
    done
}

case "$1" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    enable)   cmd_enable ;;
    disable)  cmd_disable ;;
    log)      cmd_log "${2:-50}" ;;
    list-apps) cmd_list_apps ;;
    whitelist) cmd_whitelist ;;
    restart)  cmd_stop; sleep 2; cmd_start ;;
    *)        usage ;;
esac
