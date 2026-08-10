#!/bin/bash

# ============================================================================
# Reinstall the APKs captured by phone_backup.sh onto a wiped device.
#
# Split APKs are the norm on a modern Pixel (130 files for 54 packages here),
# and `adb install base.apk` on a split package fails with
# INSTALL_FAILED_INVALID_APK -- every package therefore goes through
# `install-multiple` with its splits.
#
# Failures are expected and are NOT fatal: preinstalled system apps come back
# with the factory image, and some Play-licensed apps refuse a sideload. The
# script collects them and prints a summary instead of aborting, because a
# stop-on-first-error run would leave the restore half-done with no report.
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Never reinstall the device owner from a backup. The captured APK predates the
# release signing config and is debug-signed, so it cannot install over the
# provisioned build anyway -- but a successful downgrade would be far worse
# than a failed one, so it is skipped by name rather than left to chance.
readonly DEVICE_OWNER_PKG="com.kuhy.focus_owner"

BACKUP_DIR=""
SERIAL=""
DRY_RUN=0

usage() {
    echo "Usage: $SCRIPT_NAME --backup DIR [--serial SERIAL] [--dry-run]"
    echo "Options:"
    echo "  -b, --backup   Backup directory from phone_backup.sh (required)"
    echo "  -s, --serial   ADB serial (required when several devices attached)"
    echo "  -n, --dry-run  List what would be installed, install nothing"
    echo "  -h, --help     Show this help"
    exit 0
}

# adb with the serial applied only when one was given, so the script also
# works with a single attached device.
adb_dev() {
    if [[ -n "$SERIAL" ]]; then
        adb -s "$SERIAL" "$@"
    else
        adb "$@"
    fi
}

validate_requirements() {
    if [[ -z "$BACKUP_DIR" ]]; then
        echo "Error: --backup is required" >&2
        exit 1
    fi
    if [[ ! -d "$BACKUP_DIR/apks" ]]; then
        echo "Error: no apks/ directory under $BACKUP_DIR" >&2
        exit 1
    fi
    if ! command -v adb >/dev/null 2>&1; then
        echo "Error: adb not found. Install with: sudo pacman -S android-tools" >&2
        exit 1
    fi
    local state
    state="$(adb_dev get-state 2>/dev/null || true)"
    if [[ "$state" != "device" ]]; then
        echo "Error: device not ready (adb state: ${state:-unreachable})" >&2
        exit 1
    fi
}

# Guard the whole point of the exercise: a restore must never cost device
# ownership, and re-provisioning is impossible once an account exists.
check_device_owner() {
    local dump
    dump="$(adb_dev shell dumpsys device_policy 2>/dev/null || true)"
    if [[ "$dump" == *"Device Owner Type: 0"* ]]; then
        echo "Device owner: present (preserved by this script)"
    else
        echo "Device owner: NOT set -- continuing, but note it cannot be"
        echo "  provisioned again once any account is added."
    fi
}

install_one() {
    local pkg_dir="$1"
    local pkg
    pkg="$(basename "$pkg_dir")"

    if [[ "$pkg" == "$DEVICE_OWNER_PKG" ]]; then
        echo "  SKIP $pkg (device owner; keeping the provisioned build)"
        return 0
    fi

    local apks=()
    mapfile -t apks < <(find "$pkg_dir" -maxdepth 1 -name '*.apk' | sort)
    if [[ ${#apks[@]} -eq 0 ]]; then
        echo "  SKIP $pkg (no apk files)"
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  WOULD INSTALL $pkg (${#apks[@]} apk(s))"
        return 0
    fi

    # install-multiple handles the single-APK case too, so there is no need to
    # branch on the split/non-split distinction.
    local output
    if output="$(adb_dev install-multiple -r "${apks[@]}" 2>&1)"; then
        echo "  OK   $pkg"
        return 0
    fi

    # Trim to the failure reason; the streamed-install chatter is noise.
    local reason
    reason="$(printf '%s' "$output" | grep -oE 'INSTALL_[A-Z_]+' | head -1)"
    echo "  FAIL $pkg (${reason:-unknown})"
    return 1
}

main() {
    validate_requirements

    echo "============================================================================"
    echo "Restoring APKs from $BACKUP_DIR"
    echo "============================================================================"
    check_device_owner

    local pkg_dirs=()
    mapfile -t pkg_dirs < <(find "$BACKUP_DIR/apks" -mindepth 1 -maxdepth 1 -type d | sort)
    echo "Packages in backup: ${#pkg_dirs[@]}"
    echo

    local ok=0
    local failed=0
    local failed_pkgs=()
    local dir
    for dir in "${pkg_dirs[@]}"; do
        if install_one "$dir"; then
            ok=$((ok + 1))
        else
            failed=$((failed + 1))
            failed_pkgs+=("$(basename "$dir")")
        fi
    done

    echo
    echo "============================================================================"
    echo "Installed: $ok    Failed: $failed"
    if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
        echo "Failed packages (expected for preinstalled/Play-licensed apps):"
        printf '  %s\n' "${failed_pkgs[@]}"
    fi
    check_device_owner
    echo "============================================================================"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -b | --backup)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -s | --serial)
            SERIAL="$2"
            shift 2
            ;;
        -n | --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

main "$@"
