#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Focus Mode Daemon
# Runs on rooted Android device. Periodically checks GPS
# location and restricts non-whitelisted apps when near home.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/daemon.pid"

# ---- PID lock: exit if already running ----
acquire_lock() {
    mkdir -p "$STATE_DIR"
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            # Verify the PID is actually a focus_daemon, not a reused PID
            local cmdline
            cmdline="$(cat /proc/$old_pid/cmdline 2>/dev/null | tr '\0' ' ')"
            if echo "$cmdline" | grep -q "focus_daemon"; then
                echo "Daemon already running (PID $old_pid), exiting."
                exit 0
            fi
        fi
        # Stale or reused pidfile
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# ---- Logging ----
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$LOG_FILE"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
        local tmp="$LOG_FILE.tmp"
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$tmp"
        mv "$tmp" "$LOG_FILE"
    fi
}

# ---- Build helper files for fast package checks ----

build_whitelist_file() {
    echo "$WHITELIST" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/whitelist.txt"
}

build_sysprotect_file() {
    echo "$SYSTEM_NEVER_DISABLE" | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/sysprotect.txt"
}

reconcile_disabled_apps() {
    [ -f "$DISABLED_APPS_FILE" ] || return

    local tmp_disabled="$STATE_DIR/disabled_by_focus.tmp"
    : > "$tmp_disabled"

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue

        if is_allowed "$pkg"; then
            pm install-existing --user 0 "$pkg" >/dev/null 2>&1 || true
            pm enable "$pkg" >/dev/null 2>&1 || true
            log "Re-enabled allowed app during state reconciliation: $pkg"
            continue
        fi

        echo "$pkg" >> "$tmp_disabled"
    done < "$DISABLED_APPS_FILE"

    mv "$tmp_disabled" "$DISABLED_APPS_FILE"
}

# ---- Initialization ----
init() {
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE"
    touch "$DISABLED_APPS_FILE"
    # Ensure state files are writable (survives reboot / permission drift)
    chmod 666 "$LOG_FILE" "$DISABLED_APPS_FILE" "$PIDFILE" 2>/dev/null
    # Status file must be world-readable (companion app reads it).
    # State dir must be world-writable+executable so the companion app can
    # drop the recheck trigger file (it runs as a normal app UID).
    chmod 777 "$STATE_DIR" 2>/dev/null

    if [ "$HOME_LAT" = "0.000000" ] && [ "$HOME_LON" = "0.000000" ]; then
        log "ERROR: Home coordinates not set! Edit config.sh first."
        exit 1
    fi

    build_whitelist_file
    build_sysprotect_file
    rotate_log

    if [ -f "$MODE_FILE" ]; then
        CURRENT_MODE="$(cat "$MODE_FILE")"
    else
        CURRENT_MODE="normal"
    fi

    if [ "$CURRENT_MODE" = "focus" ]; then
        reconcile_disabled_apps
    fi

    log "Focus mode daemon started (PID=$$, mode=$CURRENT_MODE, home=$HOME_LAT,$HOME_LON, radius=${RADIUS}m)"
    log "Intervals: focus=${CHECK_INTERVAL_FOCUS}s normal=${CHECK_INTERVAL_NORMAL}s"
}

# ---- Location ----
get_location() {
    dumpsys location 2>/dev/null \
        | grep -oE '[-]?[0-9]{1,3}\.[0-9]{4,},[-]?[0-9]{1,3}\.[0-9]{4,}' \
        | head -1
}

# ---- Distance Calculation (Haversine via awk) ----
calc_distance() {
    echo "$1 $2 $3 $4" | awk '{
        PI = 3.14159265358979323846
        R = 6371000.0
        lat1 = $1 * PI / 180.0
        lon1 = $2 * PI / 180.0
        lat2 = $3 * PI / 180.0
        lon2 = $4 * PI / 180.0
        dlat = lat2 - lat1
        dlon = lon2 - lon1
        sdlat = sin(dlat / 2.0)
        sdlon = sin(dlon / 2.0)
        a = sdlat * sdlat + cos(lat1) * cos(lat2) * sdlon * sdlon
        c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        printf "%d\n", R * c
    }'
}

# ---- Check if package is allowed (whitelist or system-protected) ----
is_allowed() {
    local pkg="$1"
    # Exact match against whitelist file
    if grep -qxF "$pkg" "$STATE_DIR/whitelist.txt" 2>/dev/null; then
        return 0
    fi
    # Prefix match against system-protect file
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        case "$pkg" in
            "$prefix"*) return 0 ;;
        esac
    done < "$STATE_DIR/sysprotect.txt"
    return 1
}

# ---- Focus Mode Control ----

enable_focus_mode() {
    local first_entry=0
    if [ "$CURRENT_MODE" != "focus" ]; then
        first_entry=1
        log "ENABLING focus mode - restricting non-whitelisted apps"
        : > "$DISABLED_APPS_FILE"
    fi

    # Build blocked system app list (used both at entry and for periodic sweep)
    local blocked_sys="$STATE_DIR/blocked_sys.txt"
    echo "$BLOCKED_SYSTEM_APPS" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$blocked_sys"

    # Periodic rescan catches third-party apps the user re-enabled (e.g. via
    # Play Store or `pm enable` in a terminal) since the last tick.
    # -e = enabled only, so we skip apps that are already disabled.
    local tmp_pkgs="$STATE_DIR/pkg_list.txt"
    pm list packages -3 -e 2>/dev/null | sed 's/^package://' > "$tmp_pkgs"
    local newly_disabled=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        is_allowed "$pkg" && continue
        if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
            grep -qxF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null \
                || echo "$pkg" >> "$DISABLED_APPS_FILE"
            newly_disabled=$((newly_disabled + 1))
        fi
    done < "$tmp_pkgs"
    rm -f "$tmp_pkgs"

    # Uninstall-for-user-0 any blocked system apps (Play Store, browsers,
    # package installer UI, terminal apps). pm uninstall is idempotent:
    # re-running it on already-uninstalled-for-user-0 packages is a no-op.
    local uninstalled_sys="$STATE_DIR/uninstalled_sys.txt"
    [ "$first_entry" -eq 1 ] && : > "$uninstalled_sys"
    # List of packages installed for user 0 (one per line, "package:" prefix).
    local user0_pkgs="$STATE_DIR/user0_pkgs.txt"
    pm list packages --user 0 2>/dev/null | sed 's/^package://' > "$user0_pkgs"
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if grep -qxF "$pkg" "$user0_pkgs" 2>/dev/null; then
            if pm uninstall -k --user 0 "$pkg" >/dev/null 2>&1; then
                grep -qxF "$pkg" "$uninstalled_sys" 2>/dev/null \
                    || echo "$pkg" >> "$uninstalled_sys"
                grep -qxF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null \
                    || echo "$pkg" >> "$DISABLED_APPS_FILE"
                newly_disabled=$((newly_disabled + 1))
            fi
        fi
    done < "$blocked_sys"
    rm -f "$user0_pkgs"

    CURRENT_MODE="focus"
    echo "focus" > "$MODE_FILE"

    if [ "$first_entry" -eq 1 ]; then
        local count
        count=$(wc -l < "$DISABLED_APPS_FILE" 2>/dev/null || echo 0)
        log "Focus mode enabled - disabled $count apps"
    elif [ "$newly_disabled" -gt 0 ]; then
        log "Focus mode re-sweep: re-disabled $newly_disabled apps (re-enabled by user?)"
    fi

    reconcile_disabled_apps
}

disable_focus_mode() {
    [ "$CURRENT_MODE" = "normal" ] && return
    log "DISABLING focus mode - re-enabling apps"

    local count=0
    if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
        # Re-install system apps that were uninstalled for user
        if [ -f "$STATE_DIR/uninstalled_sys.txt" ] && [ -s "$STATE_DIR/uninstalled_sys.txt" ]; then
            while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                pm install-existing --user 0 "$pkg" >/dev/null 2>&1
            done < "$STATE_DIR/uninstalled_sys.txt"
            : > "$STATE_DIR/uninstalled_sys.txt"
        fi
        # Re-enable all disabled apps
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            pm enable "$pkg" >/dev/null 2>&1 && count=$((count + 1))
        done < "$DISABLED_APPS_FILE"
        : > "$DISABLED_APPS_FILE"
    fi

    CURRENT_MODE="normal"
    echo "normal" > "$MODE_FILE"
    log "Focus mode disabled - re-enabled $count apps"
}

# ---- Status snapshot for companion notification app ----
# Writes a tiny JSON file that focus_status_app reads every few seconds.
# Fields: mode, lat, lon, distance_m, threshold_m, radius_m, disabled_count,
# last_check_ts (unix), last_check_iso (human).
write_status_snapshot() {
    local mode="$1" lat="$2" lon="$3" dist="$4" thr="$5"
    local count iso ts
    count="$(wc -l < "$DISABLED_APPS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
    [ -z "$count" ] && count=0
    ts="$(date +%s)"
    iso="$(date '+%Y-%m-%d %H:%M:%S')"
    local tmp="$STATUS_FILE.tmp"
    # Shell-emitted JSON — keep values numeric where possible, strings quoted.
    {
        printf '{'
        printf '"mode":"%s",' "$mode"
        printf '"lat":"%s",' "${lat:-}"
        printf '"lon":"%s",' "${lon:-}"
        printf '"distance_m":%s,' "${dist:-null}"
        printf '"threshold_m":%s,' "${thr:-null}"
        printf '"radius_m":%s,' "$RADIUS"
        printf '"disabled_count":%s,' "$count"
        printf '"last_check_ts":%s,' "$ts"
        printf '"last_check_iso":"%s"' "$iso"
        printf '}\n'
    } > "$tmp" 2>/dev/null || return 0
    mv "$tmp" "$STATUS_FILE" 2>/dev/null || true
    chmod 644 "$STATUS_FILE" 2>/dev/null || true
}

# ---- Sleep with early-wake on recheck trigger ----
# Polls for $RECHECK_TRIGGER every second; if found, consumes it and returns
# early. The file can be touched by the companion app (via "Re-check now"
# button) or by `focus_ctl.sh recheck` from a shell.
sleep_with_recheck() {
    local total="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$total" ]; do
        if [ -e "$RECHECK_TRIGGER" ]; then
            rm -f "$RECHECK_TRIGGER" 2>/dev/null
            log "Manual re-check triggered"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# ---- Signal handlers ----
cleanup() {
    log "Daemon shutting down - re-enabling all apps"
    disable_focus_mode
    rm -f "$PIDFILE"
    exit 0
}

# HUP is intentionally NOT trapped so the daemon survives ADB disconnects.
# Only SIGTERM/SIGINT trigger a clean shutdown.
trap cleanup INT TERM

# ---- Main Loop ----
main() {
    acquire_lock
    init

    while true; do
        location="$(get_location)"

        if [ -n "$location" ]; then
            lat="$(echo "$location" | cut -d',' -f1)"
            lon="$(echo "$location" | cut -d',' -f2)"
            distance="$(calc_distance "$lat" "$lon" "$HOME_LAT" "$HOME_LON")"

            if [ "$CURRENT_MODE" = "focus" ]; then
                threshold=$((RADIUS + HYSTERESIS))
            else
                threshold=$((RADIUS - HYSTERESIS))
            fi

            if [ "$distance" -le "$threshold" ] 2>/dev/null; then
                enable_focus_mode
            else
                disable_focus_mode
            fi

            log "Location: $lat,$lon | Distance: ${distance}m | Threshold: ${threshold}m | Mode: $CURRENT_MODE"
            write_status_snapshot "$CURRENT_MODE" "$lat" "$lon" "$distance" "$threshold"
        else
            log "Location unavailable - defaulting to focus mode (restrictions ON)"
            enable_focus_mode
            write_status_snapshot "$CURRENT_MODE" "" "" "null" "null"
        fi

        # Dynamic interval: shorter at home (can charge), longer away (save battery).
        # sleep_with_recheck returns early if the companion app requests a recheck.
        if [ "$CURRENT_MODE" = "focus" ]; then
            sleep_with_recheck "$CHECK_INTERVAL_FOCUS"
        else
            sleep_with_recheck "$CHECK_INTERVAL_NORMAL"
        fi

        rotate_log
    done
}

main "$@"
