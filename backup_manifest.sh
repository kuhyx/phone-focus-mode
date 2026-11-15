#!/usr/bin/env bash
# backup_manifest.sh — Declarative backup and restore scope definition.
# Source this file; do not execute directly.
# Fields: name|source_path|restore_policy|requires_root|integrity_check
#
# restore_policy values:
#   safe_restore   — may be restored automatically
#   manual_only    — backed up but never restored without operator action
#   backup_only    — backed up but restore is not yet implemented

set -euo pipefail

FORMAT_DETECTION_MIN_MISSING=2

PHONE_BACKUP_ROOT="${PHONE_BACKUP_ROOT:-${HOME}/phone_backups}"

APK_ITEMS=(
    "com.qqlabs.minimalistlauncher|safe_restore|no|yes"
    "com.kuhy.focusstatus|safe_restore|no|yes"
)

APP_DATA_ITEMS=(
    "com.beemdevelopment.aegis|/data/data/com.beemdevelopment.aegis|manual_only|yes|yes"
)

MEDIA_ITEMS=(
    "photos|/sdcard/DCIM|safe_restore|no|no"
    "downloads|/sdcard/Download|safe_restore|no|no"
    "documents|/sdcard/Documents|safe_restore|no|no"
)

SECURITY_STATE_FILES=(
    "/data/adb/service.d/99-focus-mode.sh"
    "/data/local/tmp/focus_mode/hosts.canonical"
    "/data/local/tmp/focus_mode/focus_state"
)

FORMAT_INDICATORS=(
    "Magisk boot script|test -f /data/adb/service.d/99-focus-mode.sh"
    "Focus mode data dir|test -d /data/local/tmp/focus_mode"
    "Focus mode state dir|test -d /data/local/tmp/focus_mode"
    "Focus companion app installed|pm list packages -e com.kuhy.focusstatus | grep -q com.kuhy.focusstatus"
)

# Unrooted phones (the Pixel 6a): run through the plain `adb shell`, so they
# may only READ. Losing two of these three means the phone was wiped: a factory
# reset drops the Device Owner and both apps together.
FORMAT_INDICATORS_UNROOTED=(
    "Device Owner is com.kuhy.focus_owner|dpm list-owners | grep -q 'com.kuhy.focus_owner/.*DeviceOwner'"
    "Focus Owner app installed|pm list packages com.kuhy.focus_owner | grep -qx 'package:com.kuhy.focus_owner'"
    "RethinkDNS installed|pm list packages com.celzero.bravedns | grep -qx 'package:com.celzero.bravedns'"
)

BATTERY_WARN_BELOW=20
STORAGE_WARN_BELOW_MB=500
COOLDOWN_AUTO_SECS=300
# An unrooted backup copies all of shared storage (~1.3 GB), so the 30-minute
# timer runs it at most once a day; monitoring still runs every time.
BACKUP_AUTO_INTERVAL_SECS=86400
HISTORY_KEEP_DAYS=30

backup_manifest_validate() {
    local apk_entry=""
    local app_data_entry=""
    local indicator_entry=""
    local media_entry=""
    local security_file=""

    : "${PHONE_BACKUP_ROOT}"
    : "${FORMAT_DETECTION_MIN_MISSING}"
    : "${BATTERY_WARN_BELOW}"
    : "${STORAGE_WARN_BELOW_MB}"
    : "${COOLDOWN_AUTO_SECS}"
    : "${HISTORY_KEEP_DAYS}"
    : "${BACKUP_AUTO_INTERVAL_SECS}"

    for apk_entry in "${APK_ITEMS[@]}"; do
        [[ -n "${apk_entry}" ]] || return 1
    done

    for app_data_entry in "${APP_DATA_ITEMS[@]}"; do
        [[ -n "${app_data_entry}" ]] || return 1
    done

    for media_entry in "${MEDIA_ITEMS[@]}"; do
        [[ -n "${media_entry}" ]] || return 1
    done

    for security_file in "${SECURITY_STATE_FILES[@]}"; do
        [[ -n "${security_file}" ]] || return 1
    done

    for indicator_entry in "${FORMAT_INDICATORS[@]}" "${FORMAT_INDICATORS_UNROOTED[@]}"; do
        [[ -n "${indicator_entry}" ]] || return 1
    done
}

backup_manifest_validate
