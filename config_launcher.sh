#!/system/bin/sh
# shellcheck shell=ash
# config_launcher.sh — the minimalist-launcher enforcer's settings: where the
# APK and its hash live, which launchers count as competitors, and the poll
# interval and log path.
#
# Sourced by config.sh where these definitions used to sit.
#
# $LAUNCHER_PACKAGE is deliberately NOT here: focus_policy's loader reads it
# out of config.sh's text and would silently see an empty value instead.

export LAUNCHER_APK="/data/adb/focus_mode/minimalist_launcher.apk"
export LAUNCHER_SHA_FILE="/data/adb/focus_mode/minimalist_launcher.sha256"
# Captured home-activity component (package/.Activity). Saved by
# --snapshot-launcher so the enforcer knows which component to pin as HOME.
export LAUNCHER_ACTIVITY_FILE="/data/adb/focus_mode/minimalist_launcher.activity"
# Competing launchers to disable so the "pick a launcher" dialog has
# nothing else to offer. Matched exactly; add more with `focus_ctl.sh
# launcher-disable-other <pkg>`.
# com.blackview.launcher is intentionally excluded from LAUNCHER_COMPETITORS:
# Blackview embeds com.android.quickstep.RecentsActivity inside this APK,
# so disabling it kills the system-wide "swipe up for recent apps" gesture.
export LAUNCHER_COMPETITORS="
com.android.launcher
com.android.launcher3
com.google.android.apps.nexuslauncher
"
export LAUNCHER_CHECK_INTERVAL=15
export LAUNCHER_LOG="$STATE_DIR/launcher_enforcer.log"
