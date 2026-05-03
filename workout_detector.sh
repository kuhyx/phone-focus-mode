#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Workout detector for rooted Android.
#
# Why this exists:
#   The user wants YouTube unblocked ONLY while a StrongLifts workout
#   is currently in progress (i.e. started but not yet finished). This
#   daemon writes a 1/0 flag to $WORKOUT_ACTIVE_FILE; hosts_enforcer.sh
#   reads the flag and swaps the active canonical hosts file between
#   the full block ($HOSTS_CANONICAL) and the workout-relaxed variant
#   ($HOSTS_CANONICAL_WORKOUT) on transitions.
#
# Detection signal:
#   StrongLifts persists every workout to $WORKOUT_DB_PATH (SQLite).
#   The `workouts` table has columns `start` (epoch ms) and `finish`
#   (epoch ms, NULL/0 while in progress). The single source of truth:
#
#     SELECT COUNT(*) FROM workouts
#     WHERE start > 0 AND (finish IS NULL OR finish = 0);
#
#   Returns 1 during a workout, 0 otherwise. Verified empirically: every
#   completed row in the user's history has both fields populated; only
#   live workouts leave finish=NULL.
#
# Why other signals were rejected:
#   * stronglifts_timer_running pref → only true between sets (rest
#     timer); flips on/off every minute during a workout.
#   * Foreground notification → posted only during rest timer.
#   * Foreground activity → only true when actively staring at the app,
#     which is rarely the case while lifting.
#
# Failure mode:
#   Fail closed. Any error (sqlite3 missing, DB locked, query non-zero
#   exit, malformed output) writes "0" so YouTube stays blocked. Stale
#   data is preferred over an open door.
#
# Read-only DB access:
#   Uses sqlite3's URI form `file:<path>?mode=ro` to avoid touching the
#   app's WAL/SHM files or holding a write lock that StrongLifts could
#   contend with.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

PIDFILE="$STATE_DIR/workout_detector.pid"

mkdir -p "$STATE_DIR"
touch "$WORKOUT_DETECTOR_LOG"
chmod 666 "$WORKOUT_DETECTOR_LOG" 2>/dev/null || true

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $1" >> "$WORKOUT_DETECTOR_LOG"
}

rotate_log() {
    local lines
    lines="$(wc -l < "$WORKOUT_DETECTOR_LOG" 2>/dev/null || echo 0)"
    if [ "$lines" -gt 500 ]; then
        local tmp="$WORKOUT_DETECTOR_LOG.tmp"
        tail -n 500 "$WORKOUT_DETECTOR_LOG" > "$tmp"
        mv "$tmp" "$WORKOUT_DETECTOR_LOG"
    fi
}

acquire_lock() {
    if [ -f "$PIDFILE" ]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            local cmdline
            cmdline="$(tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null)"
            if echo "$cmdline" | grep -q "workout_detector"; then
                echo "workout_detector already running (PID $old_pid)"
                exit 0
            fi
        fi
        rm -f "$PIDFILE"
    fi
    echo $$ > "$PIDFILE"
}

# Write the flag atomically and chmod 666 so other daemons (running under
# different SELinux contexts) can read it. Returns 0 always; callers do not
# branch on success.
write_flag() {
    local value="$1"
    local tmp="$WORKOUT_ACTIVE_FILE.tmp"
    printf '%s\n' "$value" > "$tmp"
    mv "$tmp" "$WORKOUT_ACTIVE_FILE"
    chmod 666 "$WORKOUT_ACTIVE_FILE" 2>/dev/null || true
}

# Query StrongLifts DB. On success echoes "0" or "1"; on failure echoes
# nothing and returns non-zero so the caller can fail closed.
query_workout_active() {
    if [ ! -x "$WORKOUT_SQLITE3_BIN" ]; then
        return 1
    fi
    if [ ! -f "$WORKOUT_DB_PATH" ]; then
        # App not installed or DB not yet created → no workout possible.
        echo 0
        return 0
    fi

    local count
    count="$(
        "$WORKOUT_SQLITE3_BIN" "file:${WORKOUT_DB_PATH}?mode=ro" \
            "SELECT COUNT(*) FROM workouts WHERE start>0 AND (finish IS NULL OR finish=0);" \
            2>>"$WORKOUT_DETECTOR_LOG"
    )" || return 1

    case "$count" in
        0) echo 0 ;;
        [1-9]*) echo 1 ;;
        *)
            log "ERROR: unexpected sqlite output: '$count'"
            return 1
            ;;
    esac
    return 0
}

cleanup() {
    log "workout_detector shutting down"
    # Fail closed on shutdown — assume no workout so YouTube stays blocked.
    write_flag 0
    rm -f "$PIDFILE"
    exit 0
}

trap cleanup INT TERM

main() {
    acquire_lock
    log "workout_detector started (PID=$$, db=$WORKOUT_DB_PATH, interval=${WORKOUT_DETECTOR_INTERVAL}s)"

    local last_state="-1"

    while true; do
        local new_state
        if new_state="$(query_workout_active)"; then
            :
        else
            new_state=0
            log "WARN: query failed, defaulting workout_active=0 (fail-closed)"
        fi

        if [ "$new_state" != "$last_state" ]; then
            write_flag "$new_state"
            if [ "$new_state" = "1" ]; then
                log "STATE: workout STARTED → YouTube unblock requested"
            else
                # last_state="-1" is the very first iteration — log the
                # initial baseline distinctly so it is obvious in the log.
                if [ "$last_state" = "-1" ]; then
                    log "STATE: initial workout_active=0 (no in-progress workout)"
                else
                    log "STATE: workout FINISHED → YouTube re-block requested"
                fi
            fi
            last_state="$new_state"
        fi

        rotate_log
        sleep "$WORKOUT_DETECTOR_INTERVAL"
    done
}

main "$@"
