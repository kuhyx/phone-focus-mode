#!/bin/bash
# ============================================================
# BL-9000 Bloatware Uninstall
#
# Removes Blackview OEM bloatware and specified Google apps
# using `pm uninstall --user 0` (soft-remove, reversible via
# `pm install-existing --user 0 <pkg>`).  No reboots between
# packages — one optional reboot at the end.
#
# Usage:
#   ./batch3_bloatware_uninstall.sh [--list] [--reboot]
#
#   --list    Dry-run: show which packages would be removed.
#   --reboot  Reboot the phone after all removals.
#
# Device selection (pick one):
#   ADB_SERIAL=BL9000EEA0000102 ./batch3_bloatware_uninstall.sh
#   PHONE_IP=192.168.1.x        ./batch3_bloatware_uninstall.sh
# ============================================================

set -euo pipefail

DRY_RUN=0
DO_REBOOT=0

for arg in "$@"; do
    case "$arg" in
        --list)   DRY_RUN=1 ;;
        --reboot) DO_REBOOT=1 ;;
        *)        echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# ---- Device targeting (mirrors deploy.sh) ----
ADB_TARGET=()
if [[ -n "${ADB_SERIAL:-}" ]]; then
    ADB_TARGET=(-s "${ADB_SERIAL}")
elif [[ -n "${PHONE_IP:-}" ]]; then
    echo "Connecting to ${PHONE_IP}:5555 ..."
    adb connect "${PHONE_IP}:5555"
    ADB_TARGET=(-s "${PHONE_IP}:5555")
fi

adb_cmd() { adb "${ADB_TARGET[@]}" "$@"; }

# Requires --mount-master so the command runs in the global mount namespace.
adb_root() {
    printf '%s\n' "$1" | adb_cmd shell su --mount-master -c "sh -s"
}

# ============================================================
# PACKAGES TO REMOVE
#
# All removed with `pm uninstall --user 0` — the APK stays in
# /system so a factory reset or `pm install-existing` restores
# it.  Safe to run even if a package is absent (skipped).
# ============================================================

# ---- Blackview OEM bloatware (BL-9000 confirmed packages) ----
BV_BLOATWARE=(
    com.blackview.apkupgrade           # Blackview OTA updater
    com.blackview.bvworkspace          # BV desktop workspace
    com.blackview.childmode            # Child mode
    com.blackview.cplog                # CPU/hardware logger
    com.blackview.darkmode.one         # Dark mode theme variant
    com.blackview.darkmode.two
    com.blackview.darkmode.three
    com.blackview.easytrans            # BV easy-transfer tool
    com.blackview.filetrans            # BV file-transfer tool
    com.blackview.focusmode            # BV own focus mode (replaced by ours)
    com.blackview.frozenapp            # App freezer
    com.blackview.gamemode             # Game mode panel
    com.blackview.health               # BV health tracker
    com.blackview.helper               # BV AI assistant / helper
    # NOTE: com.blackview.launcher is intentionally NOT removed here.
    # Blackview embeds com.android.quickstep.RecentsActivity inside this APK —
    # removing it kills the "swipe up for recent apps" gesture system-wide.
    # Focus mode already disables it as a HOME competitor via LAUNCHER_COMPETITORS.
    # com.blackview.launcher
    # com.blackview.launcher.overlay.framework
    com.blackview.leftscreen           # Left swipe panel
    com.blackview.notebook             # BV notes app
    com.blackview.qrcode               # QR scanner (camera does it natively)
    com.blackview.reversepay           # Reverse wireless charging pay
    com.blackview.smscode              # SMS code extractor
    com.blackview.systemmanager        # BV system manager
    com.blackview.theme.color.mode0    # Color themes (8 variants)
    com.blackview.theme.color.mode1
    com.blackview.theme.color.mode2
    com.blackview.theme.color.mode3
    com.blackview.theme.color.mode4
    com.blackview.theme.color.mode5
    com.blackview.theme.color.mode6
    com.blackview.theme.color.mode7
    com.blackview.theme.config
    com.blackview.theme.icon.clearwave # Icon themes
    com.blackview.theme.icon.oil
    com.blackview.tool                 # BV diagnostic tool
    com.blackview.userfeedback         # BV telemetry / feedback
    com.blackview.wallpaper            # BV wallpaper collection
    com.blackview.wallpaperpicker
    com.blackview.wallpaperpicker.overlay
    com.blackview.weather              # BV weather widget
)

# ---- Google apps explicitly requested for removal ----
GOOGLE_REMOVE=(
    com.android.chrome                        # Google Chrome  (Firefox is whitelisted)
    com.google.android.youtube                # YouTube app    (hosts-blocked anyway)
    com.google.android.apps.youtube.music     # YouTube Music
)

ALL_PACKAGES=("${BV_BLOATWARE[@]}" "${GOOGLE_REMOVE[@]}")

# ============================================================
# Main
# ============================================================
echo "============================================================"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN — packages that would be removed:"
else
    echo "BL-9000 bloatware removal"
fi
echo "============================================================"

echo ""
echo "[1] Verifying device connection..."
if ! adb_cmd get-state >/dev/null 2>&1; then
    echo "ERROR: No ADB device reachable."
    echo "  Set ADB_SERIAL=<serial> or PHONE_IP=<ip> and retry."
    exit 1
fi

echo "[2] Verifying root..."
if ! adb_root "id" 2>/dev/null | grep -q "uid=0"; then
    echo "ERROR: Root shell failed. Ensure Magisk is installed."
    exit 1
fi
echo "  Root confirmed."
echo ""

removed=0
skipped=0
errors=0

for pkg in "${ALL_PACKAGES[@]}"; do
    # Check presence
    if ! adb_cmd shell pm list packages 2>/dev/null | grep -qx "package:${pkg}"; then
        printf '  %-55s [not installed]\n' "$pkg"
        (( skipped++ )) || true
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %-55s [would remove]\n' "$pkg"
        (( removed++ )) || true
        continue
    fi

    printf '  Removing %-48s ... ' "$pkg"
    result="$(adb_cmd shell pm uninstall --user 0 "$pkg" 2>&1 || true)"
    if echo "$result" | grep -qi "success"; then
        echo "OK"
        (( removed++ )) || true
    else
        echo "FAILED (${result})"
        (( errors++ )) || true
    fi
done

echo ""
echo "============================================================"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry-run complete: ${removed} would be removed, ${skipped} not installed."
    echo "Run without --list to apply."
else
    echo "Done: ${removed} removed, ${skipped} skipped (not installed), ${errors} errors."
    if [[ $DO_REBOOT -eq 1 ]]; then
        echo "Rebooting phone..."
        adb_cmd reboot
    else
        echo "Run with --reboot to reboot now, or reboot manually."
    fi
fi
echo "============================================================"
