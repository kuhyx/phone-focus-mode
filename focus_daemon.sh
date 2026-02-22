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
            echo "Daemon already running (PID $old_pid), exiting."
            exit 0
        fi
        # Stale pidfile
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

# ---- Build helper files for fast package checks ----

build_whitelist_file() {
    echo "$WHITELIST" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/whitelist.txt"
}

build_sysprotect_file() {
    echo "$SYSTEM_NEVER_DISABLE" | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/sysprotect.txt"
}

# ---- Initialization ----
init() {
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE"
    touch "$DISABLED_APPS_FILE"

    if [ "$HOME_LAT" = "0.000000" ] && [ "$HOME_LON" = "0.000000" ]; then
        log "ERROR: Home coordinates not set! Edit config.sh first."
        exit 1
    fi

    build_whitelist_file
    build_sysprotect_file

    if [ -f "$MODE_FILE" ]; then
        CURRENT_MODE="$(cat "$MODE_FILE")"
    else
        CURRENT_MODE="normal"
    fi

    LOCATION_FAIL_COUNT=0
    log "Focus mode daemon started (PID=$$, mode=$CURRENT_MODE, home=$HOME_LAT,$HOME_LON, radius=${RADIUS}m)"
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
    [ "$CURRENT_MODE" = "focus" ] && return
    log "ENABLING focus mode - restricting non-whitelisted apps"

    : > "$DISABLED_APPS_FILE"
    local tmp_pkgs="$STATE_DIR/pkg_list.txt"
    pm list packages -3 2>/dev/null | sed 's/^package://' > "$tmp_pkgs"

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        is_allowed "$pkg" && continue
        if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >> "$DISABLED_APPS_FILE"
        fi
    done < "$tmp_pkgs"
    rm -f "$tmp_pkgs"

    local count
    count=$(wc -l < "$DISABLED_APPS_FILE" 2>/dev/null || echo 0)
    CURRENT_MODE="focus"
    echo "focus" > "$MODE_FILE"
    log "Focus mode enabled - disabled $count apps"
}

disable_focus_mode() {
    [ "$CURRENT_MODE" = "normal" ] && return
    log "DISABLING focus mode - re-enabling apps"

    local count=0
    if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
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

            LOCATION_FAIL_COUNT=0
            log "Location: $lat,$lon | Distance: ${distance}m | Threshold: ${threshold}m | Mode: $CURRENT_MODE"
        else
            LOCATION_FAIL_COUNT=$((LOCATION_FAIL_COUNT + 1))
            log "Location unavailable (attempt $LOCATION_FAIL_COUNT/$MAX_LOCATION_FAILS)"

            if [ "$LOCATION_FAIL_COUNT" -ge "$MAX_LOCATION_FAILS" ]; then
                log "FAIL-SAFE: Location unavailable too long, switching to normal mode"
                disable_focus_mode
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
