#!/system/bin/sh
# shellcheck shell=ash
# config_paths.sh — the shared plumbing: poll intervals, the log file, the
# state/mode/status paths, the hosts-enforcer and workout-detector settings,
# and the boot-autostart gate.
#
# Sourced by config.sh where these definitions used to sit, after $STATE_DIR
# (which stays in config.sh, since every one of these paths is built from it).
#
# WHAT MUST NOT MOVE OUT OF config.sh
# -----------------------------------
# python_pkg/focus_policy/loader.py builds the whole policy by running a regex
# over the TEXT OF config.sh ALONE (plus a sibling config_secrets.sh). A name
# moved into any of these config_*.sh siblings becomes invisible to it, and
# the loader does not fail -- it silently yields an empty set, which reads as
# "nothing is whitelisted". These fifteen therefore stay in config.sh:
#
#   ALLOWED_PREFIXES BROWSER_PACKAGES HOME_LAT HOME_LON HYSTERESIS
#   LAUNCHER_PACKAGE NIGHT_ALLOWED_PREFIXES NIGHT_CURFEW_ENABLED
#   NIGHT_CURFEW_END NIGHT_CURFEW_START NIGHT_WHITELIST RADIUS
#   SYSTEM_NEVER_DISABLE WHITELIST WORKOUT_UNBLOCK_DOMAINS
#
# Check before and after any change here -- the hash must not move:
#   python3 -m python_pkg.focus_policy --config phone_focus_mode/config.sh \
#       | sha256sum

# Every path below is built from this, so it leads the file.
# --- State file (tracks which apps were disabled by focus mode) ---
STATE_DIR="/data/local/tmp/focus_mode"

# --- Location check interval in seconds ---
# When focus mode is ON (at home): check very frequently for near-instant
# detection of leaving home (phone is charging anyway).
# When focus mode is OFF (away): check less often to save battery.
export CHECK_INTERVAL_FOCUS=10
export CHECK_INTERVAL_NORMAL=120
# --- Log file ---
export LOG_FILE="/data/local/tmp/focus_mode/focus_mode.log"
export LOG_MAX_LINES=500
export DISABLED_APPS_FILE="$STATE_DIR/disabled_by_focus.txt"
export MODE_FILE="$STATE_DIR/current_mode.txt"
# Status snapshot consumed by the companion notification app (focus_status_app).
# Written by focus_daemon.sh every loop iteration. Chmod 644 so apps can read.
export STATUS_FILE="$STATE_DIR/status.json"
# Trigger file: companion app (or user) touches this to request an immediate
# re-check. focus_daemon.sh polls for it and skips the remainder of its sleep.
export RECHECK_TRIGGER="$STATE_DIR/trigger_recheck"
# Escape hatch: if this file exists, curfew is suspended (treated as daytime)
# everywhere — app list, grayscale, DND and network. Delete it to re-arm.
# WHO CAN CREATE IT (recovery paths, strongest lock first):
#   * `focus_ctl.sh curfew-off` over ADB from the PC  (always available daily).
#   * The Magisk boot emergency-disable file ($FOCUS_BOOT_EMERGENCY_DISABLE_FILE)
#     stops the whole stack at next boot.
#   * A root file-manager/terminal ONLY IF one is added to $NIGHT_WHITELIST.
#     None is whitelisted by default — that is deliberate ("hard to turn off").
# The active-IME guard in focus_daemon.sh keeps the keyboard alive so whichever
# path you choose is always typable. If you want a true no-PC 2am opt-out,
# whitelist a root terminal at night (see NIGHT_WHITELIST) or wire a companion-
# app button. Until then, recovery is PC/ADB-based by design.
export CURFEW_OVERRIDE_FILE="$STATE_DIR/curfew_override"
# --- Boot-time autostart safety gate ---
# Critical safety default: do NOT auto-start focus daemons at boot unless
# explicitly enabled. This avoids device instability during early boot on
# vendor ROMs after resets/updates.
# Late-auto mode: boot stack starts only after Android reports boot complete.
export FOCUS_BOOT_AUTOSTART=1
# Extra grace period after sys.boot_completed. Keep at or below 10 seconds.
export FOCUS_BOOT_DELAY_SECONDS=10
# Hard timeout while waiting for sys.boot_completed in Magisk service script.
export FOCUS_BOOT_WAIT_MAX_SECONDS=180
# Emergency kill switch file: if this marker exists on phone, boot autostart
# is skipped entirely for this boot. Create with:
#   adb shell su -c 'touch /data/local/tmp/focus_mode/disable_boot_autostart'
export FOCUS_BOOT_EMERGENCY_DISABLE_FILE="$STATE_DIR/disable_boot_autostart"
# --- Hosts enforcer state (see hosts_enforcer.sh) ---
# Canonical hosts file pushed by deploy.sh. The enforcer bind-mounts this
# over /system/etc/hosts and restores any tampering.
export HOSTS_CANONICAL="$STATE_DIR/hosts.canonical"
export HOSTS_TARGET="/system/etc/hosts"
export HOSTS_SHA_FILE="$STATE_DIR/hosts.sha256"
export HOSTS_CHECK_INTERVAL=15
export HOSTS_LOG="$STATE_DIR/hosts_enforcer.log"
# Workout-variant canonical: same content as $HOSTS_CANONICAL but with all
# YouTube-related domain blocks removed. hosts_enforcer.sh switches to this
# variant when $WORKOUT_ACTIVE_FILE contains "1" (StrongLifts workout in
# progress) and switches back when it contains "0" or is missing.
export HOSTS_CANONICAL_WORKOUT="$STATE_DIR/hosts.canonical.workout"
export HOSTS_SHA_FILE_WORKOUT="$STATE_DIR/hosts.sha256.workout"
# Magisk Systemless Hosts module path. The enforcer keeps this in sync with
# the currently-active canonical so a fresh boot sees the right hosts file.
export HOSTS_MAGISK_MODULE_FILE="/data/adb/modules/hosts/system/etc/hosts"
# --- Workout detector (see workout_detector.sh) ---
# Polls the StrongLifts SQLite DB to determine whether a workout is in
# progress. A workout is "in progress" iff there is at least one row in
# `workouts` with start>0 AND (finish IS NULL OR finish=0). While true,
# YouTube is unblocked at the hosts level (see HOSTS_CANONICAL_WORKOUT).
export WORKOUT_DETECTOR_INTERVAL=10
export WORKOUT_ACTIVE_FILE="$STATE_DIR/workout_active"
export WORKOUT_DETECTOR_LOG="$STATE_DIR/workout_detector.log"
# Static aarch64 sqlite3 binary pushed by deploy.sh. Built from the SQLite
# amalgamation against the Android NDK; ~1.6 MB. Stored outside the repo at
# ../testsAndMisc_binaries/phone_focus_mode/sqlite3 per binary-files policy.
export WORKOUT_SQLITE3_BIN="/data/local/tmp/focus_mode/sqlite3"
export WORKOUT_DB_PATH="/data/data/com.stronglifts.app/databases/StrongLifts-Database-3"
# StrongLifts package — must be in $WHITELIST so its DB stays writable while
# focus mode is enforcing. Used here only for status/log clarity.
export WORKOUT_TRIGGER_PACKAGE="com.stronglifts.app"
export BLOCKED_SYSTEM_APPS="
# *** INTENTIONALLY EMPTY ***
#
# pm disable-user state persists across reboots. Android always kills daemon
# processes with SIGKILL during shutdown, bypassing the shell cleanup trap.
# Any system package left disabled across a reboot can trigger MTK bootloop
# protection → recovery → factory wipe (confirmed on BL9000).
#
# System/distraction apps are enforced via DNS+iptables in dns_enforcer.sh
# instead of persistent package-disable state.
"
