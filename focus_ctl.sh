#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Focus Mode Control Utility
# Run on the phone via: su --mount-master -c /data/local/tmp/focus_mode/focus_ctl.sh <command>
# Or from PC via: adb shell su --mount-master -c '/data/local/tmp/focus_mode/focus_ctl.sh <command>'
# --mount-master is required so this script (and any daemon it spawns) joins
# the global mount namespace; otherwise the hosts bind mount is invisible and
# /data/adb/focus_mode/* checks fail due to per-session SELinux isolation.
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

# Emit one valid package name per line from WHITELIST.
# This strips comments/blank lines from the multi-line quoted string and avoids
# treating heading text (e.g. "---") as package tokens.
iter_whitelist_packages() {
    printf '%s\n' "$WHITELIST" | while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$line" in
            ""|\#*) continue ;;
        esac

        # Keep first token only; ignore any inline prose if present.
        set -- $line
        pkg="$1"

        # Package names are dot-delimited identifiers.
        case "$pkg" in
            *.*) ;;
            *) continue ;;
        esac
        case "$pkg" in
            *[!A-Za-z0-9._]*) continue ;;
        esac

        echo "$pkg"
    done
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
    echo "  hosts-status   - Show hosts enforcer state (mount + hash)"
    echo "  hosts-start    - Start the hosts enforcer daemon"
    echo "  hosts-stop     - Stop the hosts enforcer daemon"
    echo "  hosts-log      - Show hosts enforcer log"
    echo "  dns-status     - Show DNS enforcer state (Private DNS + iptables)"
    echo "  dns-start      - Start the DNS enforcer daemon"
    echo "  dns-stop       - Stop the DNS enforcer daemon (removes iptables chain)"
    echo "  dns-log        - Show DNS enforcer log"
    echo "  launcher-status  - Show launcher enforcer state"
    echo "  launcher-start   - Start the launcher enforcer daemon"
    echo "  launcher-stop    - Stop the launcher enforcer daemon"
    echo "  launcher-log     - Show launcher enforcer log"
    echo "  launcher-snapshot - Back up currently-installed launcher APK"
    echo "  workout-status   - Show StrongLifts workout-detection state"
    echo "  workout-start    - Start the workout detector daemon"
    echo "  workout-stop     - Stop the workout detector daemon (sets flag=0)"
    echo "  workout-log      - Show workout detector log"
    echo "  recheck    - Nudge the daemon to perform a fresh location check now"
    echo "  notif-status - Show companion status-notification details"
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
        for w in $(iter_whitelist_packages); do
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

cmd_recheck() {
    # Write the trigger file; the daemon's sleep_with_recheck() will pick it
    # up within ~1 second and perform an immediate location check.
    if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "Daemon not running - start it first with: focus_ctl.sh start"
        return 1
    fi
    touch "$RECHECK_TRIGGER"
    chmod 666 "$RECHECK_TRIGGER" 2>/dev/null || true
    echo "Recheck requested. Tail the log to see the next reading:"
    echo "  tail -f $LOG_FILE"
}

cmd_notif_status() {
    if [ -f "$STATUS_FILE" ]; then
        echo "=== $STATUS_FILE ==="
        cat "$STATUS_FILE"
        echo
    else
        echo "No status snapshot yet (daemon has not written $STATUS_FILE)."
    fi
    if command -v dumpsys >/dev/null 2>&1; then
        echo "=== Companion app state ==="
        dumpsys package com.kuhy.focusstatus 2>/dev/null | grep -E 'enabled=|installed=|userId=' | head -5 || true
    fi
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
        for w in $(iter_whitelist_packages); do
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
    for w in $(iter_whitelist_packages); do
        w="$(echo "$w" | tr -d '[:space:]')"
        [ -z "$w" ] && continue
        echo "  [allowed] $w"
    done
}

cmd_whitelist() {
    echo "=== Whitelisted packages ==="
    for w in $(iter_whitelist_packages); do
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

HOSTS_PIDFILE="$STATE_DIR/hosts_enforcer.pid"

hosts_enforcer_pid() {
    if [ -f "$HOSTS_PIDFILE" ]; then
        local pid
        pid="$(cat "$HOSTS_PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
        fi
    fi
}

cmd_hosts_status() {
    local pid
    pid="$(hosts_enforcer_pid)"
    echo "=== Hosts Enforcer Status ==="
    if [ -n "$pid" ]; then
        echo "Daemon:    RUNNING (PID $pid)"
    else
        echo "Daemon:    STOPPED"
    fi
    echo "Canonical: $HOSTS_CANONICAL"
    echo "Target:    $HOSTS_TARGET"
    if grep -qE "[[:space:]]${HOSTS_TARGET}[[:space:]]" /proc/self/mounts 2>/dev/null; then
        # A mount exists on the target path, but on Android the OEM sometimes
        # already mounts its own hosts file here. Trust the sha check below.
        echo "Mount:     present (integrity check below tells us if ours)"
    else
        echo "Mount:     NOT mounted (unprotected)"
    fi
    if [ -f "$HOSTS_CANONICAL" ]; then
        local expected actual
        expected="$(cat "$HOSTS_SHA_FILE" 2>/dev/null)"
        if command -v sha256sum >/dev/null 2>&1; then
            actual="$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{print $1}')"
        else
            actual="$(md5sum "$HOSTS_TARGET" 2>/dev/null | awk '{print $1}')"
        fi
        echo "Expected:  ${expected:-<none>}"
        echo "Actual:    ${actual:-<unreadable>}"
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            echo "Integrity: OK"
        else
            echo "Integrity: MISMATCH"
        fi
    else
        echo "Canonical hosts file missing - run deploy.sh"
    fi
}

cmd_hosts_start() {
    local pid
    pid="$(hosts_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "Hosts enforcer already running (PID $pid)"
        return
    fi
    setsid sh "$SCRIPT_DIR/hosts_enforcer.sh" </dev/null >/dev/null 2>&1 &
    sleep 2
    pid="$(hosts_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "Hosts enforcer started (PID $pid)"
    else
        echo "ERROR: hosts enforcer failed to start. Check log: $HOSTS_LOG"
    fi
}

cmd_hosts_stop() {
    local pid
    pid="$(hosts_enforcer_pid)"
    if [ -z "$pid" ]; then
        echo "Hosts enforcer not running"
        rm -f "$HOSTS_PIDFILE"
        return
    fi
    kill -TERM "$pid"
    echo "Hosts enforcer stopped (sent SIGTERM to PID $pid)"
}

cmd_hosts_log() {
    local lines="${1:-50}"
    if [ -f "$HOSTS_LOG" ]; then
        tail -n "$lines" "$HOSTS_LOG"
    else
        echo "Hosts enforcer log not found: $HOSTS_LOG"
    fi
}

# ---- DNS enforcer ----
# Hosts file only works for the system resolver. Apps using DoH/DoT bypass
# /etc/hosts entirely. The DNS enforcer forces Private DNS off and blocks
# well-known DoH/DoT endpoints so /etc/hosts is actually consulted.

DNS_PIDFILE="$STATE_DIR/dns_enforcer.pid"

dns_enforcer_pid() {
    if [ -f "$DNS_PIDFILE" ]; then
        local pid
        pid="$(cat "$DNS_PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
        fi
    fi
}

cmd_dns_status() {
    local pid
    pid="$(dns_enforcer_pid)"
    echo "=== DNS Enforcer Status ==="
    if [ -n "$pid" ]; then
        echo "Daemon:         RUNNING (PID $pid)"
    else
        echo "Daemon:         STOPPED"
    fi
    local mode spec
    mode="$(settings get global private_dns_mode 2>/dev/null)"
    spec="$(settings get global private_dns_specifier 2>/dev/null)"
    echo "private_dns_mode:      ${mode:-<unset>}"
    echo "private_dns_specifier: ${spec:-<unset>}"
    if iptables -L "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
        local v4rules
        v4rules="$(iptables -S "$DNS_IPT_CHAIN" 2>/dev/null | wc -l)"
        echo "iptables $DNS_IPT_CHAIN: $v4rules rules"
    else
        echo "iptables $DNS_IPT_CHAIN: MISSING"
    fi
    if ip6tables -L "$DNS_IPT_CHAIN" >/dev/null 2>&1; then
        local v6rules
        v6rules="$(ip6tables -S "$DNS_IPT_CHAIN" 2>/dev/null | wc -l)"
        echo "ip6tables $DNS_IPT_CHAIN: $v6rules rules"
    else
        echo "ip6tables $DNS_IPT_CHAIN: MISSING"
    fi
}

cmd_dns_start() {
    local pid
    pid="$(dns_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "DNS enforcer already running (PID $pid)"
        return
    fi
    setsid sh "$SCRIPT_DIR/dns_enforcer.sh" </dev/null >/dev/null 2>&1 &
    sleep 2
    pid="$(dns_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "DNS enforcer started (PID $pid)"
    else
        echo "ERROR: DNS enforcer failed to start. Check log: $DNS_LOG"
    fi
}

cmd_dns_stop() {
    local pid
    pid="$(dns_enforcer_pid)"
    if [ -z "$pid" ]; then
        echo "DNS enforcer not running"
        rm -f "$DNS_PIDFILE"
    else
        kill -TERM "$pid"
        echo "DNS enforcer stopped (sent SIGTERM to PID $pid)"
    fi
    # Explicit teardown of the iptables chain so maintenance work can
    # use DoH. The enforcer itself leaves the chain intact on TERM to
    # keep the block closed between periodic re-applies.
    iptables -D OUTPUT -j "$DNS_IPT_CHAIN" 2>/dev/null || true
    iptables -F "$DNS_IPT_CHAIN" 2>/dev/null || true
    iptables -X "$DNS_IPT_CHAIN" 2>/dev/null || true
    ip6tables -D OUTPUT -j "$DNS_IPT_CHAIN" 2>/dev/null || true
    ip6tables -F "$DNS_IPT_CHAIN" 2>/dev/null || true
    ip6tables -X "$DNS_IPT_CHAIN" 2>/dev/null || true
    echo "iptables chain $DNS_IPT_CHAIN removed"
}

cmd_dns_log() {
    local lines="${1:-50}"
    if [ -f "$DNS_LOG" ]; then
        tail -n "$lines" "$DNS_LOG"
    else
        echo "DNS enforcer log not found: $DNS_LOG"
    fi
}

# ---- Launcher enforcer ----

LAUNCHER_PIDFILE="$STATE_DIR/launcher_enforcer.pid"
DISABLED_COMPETITORS_FILE="$STATE_DIR/disabled_competitors.txt"

launcher_enforcer_pid() {
    if [ -f "$LAUNCHER_PIDFILE" ]; then
        local pid
        pid="$(cat "$LAUNCHER_PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
        fi
    fi
}

cmd_launcher_snapshot() {
    # Find the APK path for the currently-installed launcher and copy it
    # to LAUNCHER_APK. Also capture the current HOME activity component.
    local apk_path
    apk_path="$(pm path "$LAUNCHER_PACKAGE" 2>/dev/null | head -1 | sed 's/^package://')"
    if [ -z "$apk_path" ] || [ ! -f "$apk_path" ]; then
        echo "ERROR: $LAUNCHER_PACKAGE is not installed. Install it once via Aurora/Play Store, then rerun this command."
        return 1
    fi
    mkdir -p "$(dirname "$LAUNCHER_APK")"
    chattr -i "$LAUNCHER_APK" "$LAUNCHER_SHA_FILE" "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null || true
    cp "$apk_path" "$LAUNCHER_APK" || return 1
    chmod 644 "$LAUNCHER_APK"
    sha256sum "$LAUNCHER_APK" | awk '{print $1}' > "$LAUNCHER_SHA_FILE"
    chmod 644 "$LAUNCHER_SHA_FILE"

    # Resolve the current HOME activity (or the launcher's default activity
    # if it isn't yet the default).
    local component
    component="$(cmd package resolve-activity --brief \
        -c android.intent.category.HOME \
        -a android.intent.action.MAIN 2>/dev/null | awk 'NR==2{print}')"
    if [ -z "$component" ] || [ "${component%%/*}" != "$LAUNCHER_PACKAGE" ]; then
        # Fall back to the launcher's MAIN/LAUNCHER activity
        component="$(cmd package resolve-activity --brief \
            -c android.intent.category.LAUNCHER \
            -a android.intent.action.MAIN "$LAUNCHER_PACKAGE" 2>/dev/null \
            | awk 'NR==2{print}')"
    fi
    if [ -z "$component" ]; then
        echo "ERROR: could not resolve HOME activity for $LAUNCHER_PACKAGE"
        return 1
    fi
    echo "$component" > "$LAUNCHER_ACTIVITY_FILE"
    chmod 644 "$LAUNCHER_ACTIVITY_FILE"

    # Make snapshot immutable so even root-in-a-terminal can't overwrite
    # it without first running `chattr -i`.
    chattr +i "$LAUNCHER_APK" "$LAUNCHER_SHA_FILE" "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null || true

    echo "Snapshot saved:"
    echo "  APK:      $LAUNCHER_APK ($(wc -c < "$LAUNCHER_APK") bytes)"
    echo "  SHA256:   $(cat "$LAUNCHER_SHA_FILE")"
    echo "  Activity: $component"
}

cmd_launcher_status() {
    local pid
    pid="$(launcher_enforcer_pid)"
    echo "=== Launcher Enforcer Status ==="
    if [ -n "$pid" ]; then
        echo "Daemon:     RUNNING (PID $pid)"
    else
        echo "Daemon:     STOPPED"
    fi
    echo "Package:    $LAUNCHER_PACKAGE"
    if pm path "$LAUNCHER_PACKAGE" >/dev/null 2>&1; then
        echo "Installed:  YES ($(pm path "$LAUNCHER_PACKAGE" | head -1))"
    else
        echo "Installed:  NO"
    fi
    local desired actual
    desired="$(cat "$LAUNCHER_ACTIVITY_FILE" 2>/dev/null)"
    actual="$(cmd package resolve-activity --brief \
        -c android.intent.category.HOME -a android.intent.action.MAIN \
        2>/dev/null | awk 'NR==2{print}')"
    echo "Expected:   ${desired:-<not armed - run launcher-snapshot>}"
    echo "Actual:     ${actual:-<unresolved>}"
    if [ -n "$desired" ] && [ "$desired" = "$actual" ]; then
        echo "Default:    OK (pinned)"
    else
        echo "Default:    MISMATCH"
    fi
    echo "Snapshot:   $LAUNCHER_APK"
    if [ -f "$LAUNCHER_APK" ]; then
        echo "Snapshot size: $(wc -c < "$LAUNCHER_APK") bytes"
    fi
    if [ -s "$DISABLED_COMPETITORS_FILE" ]; then
        echo "Disabled competitors:"
        sed 's/^/  - /' "$DISABLED_COMPETITORS_FILE"
    fi
}

cmd_launcher_start() {
    local pid
    pid="$(launcher_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "Launcher enforcer already running (PID $pid)"
        return
    fi
    setsid sh "$SCRIPT_DIR/launcher_enforcer.sh" </dev/null >/dev/null 2>&1 &
    sleep 2
    pid="$(launcher_enforcer_pid)"
    if [ -n "$pid" ]; then
        echo "Launcher enforcer started (PID $pid)"
    else
        echo "ERROR: launcher enforcer failed to start. Check log: $LAUNCHER_LOG"
    fi
}

cmd_launcher_stop() {
    local pid
    pid="$(launcher_enforcer_pid)"
    if [ -z "$pid" ]; then
        echo "Launcher enforcer not running"
        rm -f "$LAUNCHER_PIDFILE"
    else
        kill -TERM "$pid"
        echo "Launcher enforcer stopped (sent SIGTERM to PID $pid)"
    fi
    # Re-enable any competitors we disabled so the device is usable if the
    # enforcer is intentionally stopped (e.g. during maintenance).
    if [ -s "$DISABLED_COMPETITORS_FILE" ]; then
        while read -r pkg; do
            [ -z "$pkg" ] && continue
            pm enable --user 0 "$pkg" >/dev/null 2>&1 && \
                echo "Re-enabled competing launcher: $pkg"
        done < "$DISABLED_COMPETITORS_FILE"
        : > "$DISABLED_COMPETITORS_FILE"
    fi
}

cmd_launcher_log() {
    local lines="${1:-50}"
    if [ -f "$LAUNCHER_LOG" ]; then
        tail -n "$lines" "$LAUNCHER_LOG"
    else
        echo "Launcher enforcer log not found: $LAUNCHER_LOG"
    fi
}

# ---- Workout detector ----

WORKOUT_PIDFILE="$STATE_DIR/workout_detector.pid"

workout_detector_pid() {
    if [ -f "$WORKOUT_PIDFILE" ]; then
        local pid
        pid="$(cat "$WORKOUT_PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
        fi
    fi
}

cmd_workout_status() {
    local pid
    pid="$(workout_detector_pid)"
    echo "=== Workout Detector Status ==="
    if [ -n "$pid" ]; then
        echo "Daemon:        RUNNING (PID $pid)"
    else
        echo "Daemon:        STOPPED"
    fi
    echo "Package:       $WORKOUT_TRIGGER_PACKAGE"
    if pm path "$WORKOUT_TRIGGER_PACKAGE" >/dev/null 2>&1; then
        echo "Installed:     YES"
    else
        echo "Installed:     NO (detector will always report inactive)"
    fi
    echo "sqlite3:       $WORKOUT_SQLITE3_BIN"
    if [ -x "$WORKOUT_SQLITE3_BIN" ]; then
        echo "sqlite3 ver:   $("$WORKOUT_SQLITE3_BIN" -version 2>/dev/null | awk '{print $1}')"
    else
        echo "sqlite3 ver:   <missing or not executable — detector cannot query DB>"
    fi
    echo "DB path:       $WORKOUT_DB_PATH"
    if [ -f "$WORKOUT_DB_PATH" ]; then
        echo "DB present:    YES"
    else
        echo "DB present:    NO"
    fi
    echo "Poll interval: ${WORKOUT_DETECTOR_INTERVAL}s"
    local flag="<unset>"
    if [ -f "$WORKOUT_ACTIVE_FILE" ]; then
        flag="$(cat "$WORKOUT_ACTIVE_FILE" 2>/dev/null)"
    fi
    case "$flag" in
        1) echo "Workout flag:  1 (workout IN PROGRESS → YouTube hosts UNBLOCKED)" ;;
        0) echo "Workout flag:  0 (no workout → YouTube hosts BLOCKED)" ;;
        *) echo "Workout flag:  '$flag' (treated as 0, fail-closed)" ;;
    esac
    # Live one-shot query so the user can see ground truth without waiting
    # for the next poll cycle. Best-effort — never fails the status command.
    if [ -x "$WORKOUT_SQLITE3_BIN" ] && [ -f "$WORKOUT_DB_PATH" ]; then
        local live_count
        live_count="$("$WORKOUT_SQLITE3_BIN" "file:${WORKOUT_DB_PATH}?mode=ro" \
            "SELECT COUNT(*) FROM workouts WHERE start>0 AND (finish IS NULL OR finish=0);" \
            2>/dev/null)"
        echo "Live DB query: in-progress workouts = ${live_count:-<query failed>}"
    fi
    if [ -f "$HOSTS_CANONICAL_WORKOUT" ]; then
        echo "Workout hosts: $HOSTS_CANONICAL_WORKOUT ($(wc -l < "$HOSTS_CANONICAL_WORKOUT" 2>/dev/null) lines)"
    else
        echo "Workout hosts: <missing — deploy.sh must regenerate it>"
    fi
}

cmd_workout_start() {
    local pid
    pid="$(workout_detector_pid)"
    if [ -n "$pid" ]; then
        echo "Workout detector already running (PID $pid)"
        return
    fi
    if [ ! -x "$WORKOUT_SQLITE3_BIN" ]; then
        echo "ERROR: $WORKOUT_SQLITE3_BIN missing or not executable. Re-run deploy.sh."
        return 1
    fi
    setsid sh "$SCRIPT_DIR/workout_detector.sh" </dev/null >/dev/null 2>&1 &
    sleep 2
    pid="$(workout_detector_pid)"
    if [ -n "$pid" ]; then
        echo "Workout detector started (PID $pid)"
    else
        echo "ERROR: Workout detector failed to start. Check log: $WORKOUT_DETECTOR_LOG"
    fi
}

cmd_workout_stop() {
    local pid
    pid="$(workout_detector_pid)"
    if [ -z "$pid" ]; then
        echo "Workout detector not running"
        rm -f "$WORKOUT_PIDFILE"
    else
        kill -TERM "$pid"
        echo "Workout detector stopped (sent SIGTERM to PID $pid)"
    fi
    # Fail-closed on manual stop: write 0 so the hosts enforcer reverts to
    # the full-block canonical and YouTube goes back to being blocked.
    printf '0\n' > "$WORKOUT_ACTIVE_FILE" 2>/dev/null || true
    chmod 666 "$WORKOUT_ACTIVE_FILE" 2>/dev/null || true
    echo "workout_active flag forced to 0"
}

cmd_workout_log() {
    local lines="${1:-50}"
    if [ -f "$WORKOUT_DETECTOR_LOG" ]; then
        tail -n "$lines" "$WORKOUT_DETECTOR_LOG"
    else
        echo "Workout detector log not found: $WORKOUT_DETECTOR_LOG"
    fi
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
    hosts-status) cmd_hosts_status ;;
    hosts-start)  cmd_hosts_start ;;
    hosts-stop)   cmd_hosts_stop ;;
    hosts-log)    cmd_hosts_log "${2:-50}" ;;
    dns-status)   cmd_dns_status ;;
    dns-start)    cmd_dns_start ;;
    dns-stop)     cmd_dns_stop ;;
    dns-log)      cmd_dns_log "${2:-50}" ;;
    launcher-status)   cmd_launcher_status ;;
    launcher-start)    cmd_launcher_start ;;
    launcher-stop)     cmd_launcher_stop ;;
    launcher-log)      cmd_launcher_log "${2:-50}" ;;
    launcher-snapshot) cmd_launcher_snapshot ;;
    workout-status)    cmd_workout_status ;;
    workout-start)     cmd_workout_start ;;
    workout-stop)      cmd_workout_stop ;;
    workout-log)       cmd_workout_log "${2:-50}" ;;
    recheck)   cmd_recheck ;;
    notif-status) cmd_notif_status ;;
    *)        usage ;;
esac
