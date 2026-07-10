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
    # Sanity check: the WHITELIST string in config.sh is fragile - any
    # literal double-quote inside a comment will close the heredoc and
    # silently truncate the variable. Log the parsed line count so any
    # future regression is visible in the log, and warn loudly if it
    # falls below a known floor (we always have ~70+ entries).
    local n
    n=$(wc -l < "$STATE_DIR/whitelist.txt" 2>/dev/null | tr -d ' ')
    log "Whitelist parsed: $n entries"
    if [ "${n:-0}" -lt 30 ]; then
        log "WARN: whitelist suspiciously small ($n lines) - check config.sh for stray quotes inside WHITELIST string"
    fi
}

build_night_whitelist_file() {
    # Strict allow-list used while the night curfew is active (see config.sh
    # NIGHT_WHITELIST and is_curfew_now()). Parsed exactly like the day list.
    echo "$NIGHT_WHITELIST" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/night_whitelist.txt"
    local n
    n=$(wc -l < "$STATE_DIR/night_whitelist.txt" 2>/dev/null | tr -d ' ')
    log "Night-curfew whitelist parsed: $n entries"
    if [ "${n:-0}" -lt 10 ]; then
        log "WARN: night whitelist suspiciously small ($n lines) - check config.sh for stray quotes inside NIGHT_WHITELIST string"
    fi
}

build_sysprotect_file() {
    echo "$SYSTEM_NEVER_DISABLE" | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/sysprotect.txt"
}

# $BLOCKED_SYSTEM_APPS is a static config value (never changes without a
# daemon restart), so - like build_sysprotect_file above - this only needs
# to run once at startup, not every enable_focus_mode() sweep.
build_blocked_sys_file() {
    echo "$BLOCKED_SYSTEM_APPS" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STATE_DIR/blocked_sys.txt"
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
        log "ERROR: Home coordinates not set! Edit config_secrets.sh first."
        exit 1
    fi

    if ! echo "$HOME_LAT" | grep -Eq '^[-]?[0-9]+(\.[0-9]+)?$'; then
        log "ERROR: HOME_LAT is invalid ('$HOME_LAT'). Expected decimal degrees in config_secrets.sh"
        exit 1
    fi

    if ! echo "$HOME_LON" | grep -Eq '^[-]?[0-9]+(\.[0-9]+)?$'; then
        log "ERROR: HOME_LON is invalid ('$HOME_LON'). Expected decimal degrees in config_secrets.sh"
        exit 1
    fi

    build_whitelist_file
    build_night_whitelist_file
    build_sysprotect_file
    build_blocked_sys_file
    refresh_default_handlers
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

# ---- Night curfew time check ----
# Returns 0 (true) when the local clock is inside the curfew window.
# Fails OPEN (return 1 = not curfew) on a malformed clock so a broken `date`
# can never strand you behind the strict list — essentials stay reachable
# either way, but the day list is the less-surprising default.
_dec() {
    # Strip leading zeros so a zero-padded HHMM ("0500", "0830") is not parsed
    # as (sometimes invalid) octal by the shell's arithmetic. Portable across
    # ash/mksh; keeps at least one digit so "0000" -> "0".
    local n="$1"
    while [ "${n#0}" != "$n" ] && [ "${#n}" -gt 1 ]; do n="${n#0}"; done
    printf '%s' "$n"
}

is_curfew_now() {
    local now start end
    now="$(date +%H%M 2>/dev/null)"
    case "$now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now="$(_dec "$now")"; start="$(_dec "$NIGHT_CURFEW_START")"; end="$(_dec "$NIGHT_CURFEW_END")"
    if [ "$start" -le "$end" ]; then
        [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
    else
        # Window wraps past midnight (e.g. 2300 -> 0500).
        [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
    fi
}

# Curfew is ACTIVE when enabled, not manually overridden, and either forced on
# (test hook) or inside the time window. The is_allowed() switch below consults
# this; because is_allowed() only runs during the focus-mode sweep/reconcile,
# curfew automatically takes effect only at home and is a no-op when away.
#
# Memoized once per main-loop tick (reset at the top of main()'s while loop):
# is_allowed() calls this once per enabled package in the sweep, and
# is_curfew_now forks `date` - on-device this meant up to ~N extra forks per
# 10s tick for N enabled apps, all recomputing a value that cannot change
# within a single tick. Result is cached in _CURFEW_TICK_RESULT.
curfew_active() {
    if [ -n "$_CURFEW_TICK_CACHED" ]; then
        [ "$_CURFEW_TICK_RESULT" = "1" ]
        return
    fi
    _CURFEW_TICK_CACHED=1
    _CURFEW_TICK_RESULT=0
    if [ "${NIGHT_CURFEW_ENABLED:-0}" = "1" ] && [ ! -e "$CURFEW_OVERRIDE_FILE" ]; then
        if [ -e "$CURFEW_FORCE_FILE" ] || is_curfew_now; then
            _CURFEW_TICK_RESULT=1
        fi
    fi
    [ "$_CURFEW_TICK_RESULT" = "1" ]
}

# ---- Check if package is allowed (whitelist or system-protected) ----
is_allowed() {
    local pkg="$1"
    # During the night curfew, swap the permissive day list for the strict
    # night list. The sysprotect + default-handler guards below still apply on
    # top of whichever list is active.
    local list="$STATE_DIR/whitelist.txt"
    if curfew_active; then
        list="$STATE_DIR/night_whitelist.txt"
    fi
    # Exact match against the active whitelist file
    if grep -qxF "$pkg" "$list" 2>/dev/null; then
        return 0
    fi
    # Prefix match against system-protect file
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        case "$pkg" in
            "$prefix"*) return 0 ;;
        esac
    done < "$STATE_DIR/sysprotect.txt"
    # Hard-stop guard: refuse to disable any package that is the current
    # default handler for a critical role (Dialer / SMS / Home / Contacts).
    # Without this, a misconfigured WHITELIST can disable the default Phone
    # app and Android falls back to com.android.settings/.FallbackHome -
    # the persistent "Phone is starting..." screen with broken SystemUI
    # gestures (no swipe-up recents). Recovering requires `pm enable` over
    # ADB. Treat the guard as last-resort safety net independent of WHITELIST
    # contents so a future config edit can never wipe these out.
    is_default_handler "$pkg" && return 0
    # The default browser is guarded only OUTSIDE curfew. At night the whole
    # point is to disable browsers, so this guard must not re-allow it.
    if ! curfew_active \
        && grep -qxF "$pkg" "$STATE_DIR/default_browser.txt" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---- Default handler detection ----
# Refreshed once per focus_daemon tick into $STATE_DIR/default_handlers.txt.
# Each line is a package name. Lookup is a cheap grep against this file.
refresh_default_handlers() {
    local f="$STATE_DIR/default_handlers.txt"
    local tmp="$f.tmp"
    : > "$tmp"
    # Default Home (launcher). resolve-activity prints "Activity Resolver Table:"
    # on line 1 and "<pkg>/<.Activity>" on line 2 in --brief mode.
    cmd package resolve-activity --brief \
        -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null \
        | awk -F/ 'NR==2 && $1 != "" {print $1}' >> "$tmp"
    # Default Dialer
    local dialer
    dialer="$(cmd telecom get-default-dialer 2>/dev/null | tr -d '[:space:]')"
    [ -n "$dialer" ] && echo "$dialer" >> "$tmp"
    # Default SMS handler (settings provider key)
    local sms
    sms="$(settings get secure sms_default_application 2>/dev/null | tr -d '[:space:]')"
    [ -n "$sms" ] && [ "$sms" != "null" ] && echo "$sms" >> "$tmp"
    # Default input method (active keyboard). Disabling the active IME with
    # pm disable-user PERSISTS across reboot; a 1am reboot would then leave no
    # keyboard to type any recovery command. Protect it day and night so the
    # curfew can never lock you out of typing.
    local ime
    ime="$(settings get secure default_input_method 2>/dev/null | cut -d/ -f1)"
    [ -n "$ime" ] && [ "$ime" != "null" ] && echo "$ime" >> "$tmp"
    sort -u "$tmp" -o "$f"
    rm -f "$tmp"

    # Default Browser handler is tracked SEPARATELY and guarded only OUTSIDE
    # the curfew window (see is_allowed). During curfew the whole point is to
    # disable browsers, so the default-handler guard must not resurrect them.
    local bf="$STATE_DIR/default_browser.txt"
    cmd package resolve-activity --brief \
        -a android.intent.action.VIEW -d http://example.com 2>/dev/null \
        | awk -F/ 'NR==2 && $1 != "" {print $1}' > "$bf.tmp" 2>/dev/null
    mv "$bf.tmp" "$bf" 2>/dev/null || : > "$bf"
}

is_default_handler() {
    local pkg="$1"
    grep -qxF "$pkg" "$STATE_DIR/default_handlers.txt" 2>/dev/null
}

# ---- Focus Mode Control ----

enable_focus_mode() {
    local first_entry=0
    if [ "$CURRENT_MODE" != "focus" ]; then
        first_entry=1
        log "ENABLING focus mode - restricting non-whitelisted apps"
        : > "$DISABLED_APPS_FILE"
    fi

    # Refresh default-handler list every tick. The user may switch dialer /
    # SMS / launcher between sweeps; the guard in is_allowed() consults this
    # list so a newly-promoted handler is never disabled.
    refresh_default_handlers

    # Blocked system app list is static; built once in init() (see
    # build_blocked_sys_file), not rebuilt on every sweep.
    local blocked_sys="$STATE_DIR/blocked_sys.txt"

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

    # Disable-for-user-0 any blocked system apps (Play Store, browsers,
    # package installer UI, terminal apps).
    # IMPORTANT: We intentionally use pm disable-user (NOT pm uninstall) here.
    # pm uninstall -k --user 0 removes the package from Android's user-0
    # package registry. If the daemon is killed with SIGKILL during a reboot
    # (bypassing the cleanup trap), those packages stay uninstalled across the
    # reboot. Android's bootloop-protection (MTK and others) then detects
    # missing critical system packages and triggers recovery / factory wipe.
    # pm disable-user leaves the package registered but inactive, so the
    # PackageManager scan at next boot succeeds and no wipe occurs.
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
            grep -qxF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null \
                || echo "$pkg" >> "$DISABLED_APPS_FILE"
            newly_disabled=$((newly_disabled + 1))
        fi
    done < "$blocked_sys"

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
        # Re-enable all disabled apps (both 3rd-party and system apps).
        # Both paths now use pm disable-user, so pm enable is the only
        # restore command needed.
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
    local count iso ts cf ov frc
    count="$(wc -l < "$DISABLED_APPS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
    [ -z "$count" ] && count=0
    ts="$(date +%s)"
    iso="$(date '+%Y-%m-%d %H:%M:%S')"
    # Curfew state for the companion app: 1/0 so it slots into the existing
    # numeric JSON path. "curfew" = restrictions active now; "curfew_override"
    # = the escape-hatch file is set (curfew suspended).
    if curfew_active; then cf=1; else cf=0; fi
    if [ -e "$CURFEW_OVERRIDE_FILE" ]; then ov=1; else ov=0; fi
    # "curfew_force" = the demo/test force file is set (curfew forced on
    # regardless of clock). Lets the companion app show Start/Stop demo.
    if [ -e "$CURFEW_FORCE_FILE" ]; then frc=1; else frc=0; fi
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
        printf '"curfew":%s,' "$cf"
        printf '"curfew_override":%s,' "$ov"
        printf '"curfew_force":%s,' "$frc"
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
        # Invalidate the per-tick curfew_active() memo (see its definition).
        _CURFEW_TICK_CACHED=""

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

            curfew_state="day"; curfew_active && curfew_state="CURFEW"
            log "Location: $lat,$lon | Distance: ${distance}m | Threshold: ${threshold}m | Mode: $CURRENT_MODE | Curfew: $curfew_state"
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
