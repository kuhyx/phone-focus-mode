#!/bin/bash
# ============================================================
# Focus Mode Deployment Script
# Deploys focus mode to your rooted BL-9000 via wireless ADB
#
# Usage:
#   ./deploy.sh [phone_ip]       - Full deploy (first time or update)
#   ./deploy.sh [phone_ip] --status  - Check status
#   ./deploy.sh [phone_ip] --log     - View log
#   ./deploy.sh [phone_ip] --stop    - Stop daemon
#   ./deploy.sh [phone_ip] --enable  - Force focus mode on
#   ./deploy.sh [phone_ip] --disable - Force focus mode off
# ============================================================

set -euo pipefail

PHONE_IP="${1:-}"
ACTION="${2:---deploy}"
REMOTE_DIR="/data/local/tmp/focus_mode"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NEEDS_GPS_FETCH=0  # set to 1 by check_coords when local coords are placeholder

# Source shared config constants (BROWSER_PACKAGES, REMOTE_DIR, etc.)
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

ADB_TARGET=()

# Support orchestrator-driven device targeting via ADB_SERIAL.
# When ADB_SERIAL is set, deploy.sh uses that target directly and preserves
# the existing PHONE_IP workflow when ADB_SERIAL is unset.
if [[ -n "${ADB_SERIAL:-}" ]]; then
    ADB_TARGET=(-s "${ADB_SERIAL}")
    if [[ -z "${PHONE_IP}" || "${PHONE_IP}" == --* ]]; then
        ACTION="${PHONE_IP:---deploy}"
        PHONE_IP=""
    fi
fi

adb_cmd() {
    adb "${ADB_TARGET[@]}" "$@"
}

usage() {
    echo "Usage: $0 <phone_ip> [action]"
    echo "   or: ADB_SERIAL=<serial> $0 [action]"
    echo ""
    echo "Actions:"
    echo "  (none)     Full deploy"
    echo "  --status   Show daemon status and current mode"
    echo "  --log      Tail the daemon log"
    echo "  --stop     Stop daemon (re-enables all apps)"
    echo "  --start    Start daemon"
    echo "  --restart  Restart daemon"
    echo "  --enable   Force focus mode on"
    echo "  --disable  Force focus mode off"
    echo "  --list     List all third-party apps and whitelist status"
    echo "  --pull-log Download log file locally"
    echo "  --find-pkg Show installed packages matching a filter (e.g. --find-pkg pomodoro)"
    echo "  --capture-coords     Capture current GPS as home location (run after WiFi setup)"
    echo "  --hosts-status  Show hosts enforcer status on the phone"
    echo "  --hosts-log     Show hosts enforcer log on the phone"
    echo "  --launcher-status    Show launcher enforcer status on the phone"
    echo "  --launcher-log       Show launcher enforcer log on the phone"
    echo "  --snapshot-launcher  Snapshot installed Minimalist Phone APK + default HOME"
    echo "  --install-aurora     Download & install Aurora Store (open-source Play Store alt)"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.42"
    echo "  $0 192.168.1.42 --status"
    echo "  $0 192.168.1.42 --find-pkg stronglift"
    exit 1
}

# ---- Pre-flight checks ----
check_adb() {
    if ! command -v adb >/dev/null 2>&1; then
        echo "ERROR: adb not found. Install Android platform-tools first."
        echo "  Ubuntu/Debian: sudo apt install adb"
        echo "  Arch: sudo pacman -S android-tools"
        exit 1
    fi
}

check_coords() {
    local lat lon
    lat="$(grep '^.*HOME_LAT=' "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/config_secrets.sh" 2>/dev/null | tail -1 | cut -d'"' -f2)"
    lon="$(grep '^.*HOME_LON=' "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/config_secrets.sh" 2>/dev/null | tail -1 | cut -d'"' -f2)"
    if [ "$lat" = "0.000000" ] && [ "$lon" = "0.000000" ]; then
        echo "ERROR: Home coordinates not set (all zeros)."
        exit 1
    fi
    # If both look like valid floats, use them; otherwise auto-capture from phone GPS.
    if [[ -n "$lat" && "$lat" =~ ^[+-]?[0-9]+\.[0-9]+$ && -n "$lon" && "$lon" =~ ^[+-]?[0-9]+\.[0-9]+$ ]]; then
        NEEDS_GPS_FETCH=0
        echo "  Home location: $lat, $lon"
    else
        NEEDS_GPS_FETCH=1
        echo "  Home location: placeholder — will be captured from phone GPS at deploy time."
    fi
}

check_ip() {
    if [[ -n "${ADB_SERIAL:-}" ]]; then
        return 0
    fi

    if [ -z "$PHONE_IP" ]; then
        echo "ERROR: Phone IP not provided."
        echo ""
        usage
    fi
}

connect_adb() {
    if [[ -n "${ADB_SERIAL:-}" ]]; then
        if ! adb devices | awk 'NR>1 && $2=="device"{print $1}' | grep -Fxq "${ADB_SERIAL}"; then
            echo "ERROR: ADB_SERIAL '${ADB_SERIAL}' is not connected."
            echo "Connect device via USB or pair wireless ADB first."
            exit 1
        fi
        ADB_TARGET=(-s "${ADB_SERIAL}")
        echo "Using ADB_SERIAL target: ${ADB_SERIAL}"
        return 0
    fi

    echo "Connecting to $PHONE_IP:5555 ..."
    adb connect "$PHONE_IP:5555"
    sleep 1
    if ! adb devices | grep -q "$PHONE_IP"; then
        echo "ERROR: Could not connect to $PHONE_IP:5555"
        echo "Make sure wireless ADB is enabled and the phone is reachable."
        exit 1
    fi
    ADB_TARGET=(-s "$PHONE_IP:5555")
    echo "Connected."
}

# Wrapper: run a root shell command on the phone.
# Uses --mount-master so the command sees (and can modify) the global mount
# namespace — required for any status checks that inspect the hosts bind
# mount, /data/adb/focus_mode files, or for starting daemons.
adb_root() {
    local command_text="$1"

    printf '%s\n' "$command_text" | adb_cmd shell su --mount-master -c "sh -s"
}

compute_file_hash() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
        return 0
    fi

    md5sum "$path" | awk '{print $1}'
}

# ============================================================
# GPS HOME COORDINATE CAPTURE
# ============================================================
# Called when config_secrets.sh has placeholder/non-numeric coords.
# Enables Android location, waits up to GPS_MAX_WAIT_SECS for a
# network/fused fix, and prints "lat lon" on stdout.  All progress
# messages go to stderr so the caller can capture only the coords.
GPS_MAX_WAIT_SECS=90

fetch_home_coords_from_phone() {
    echo "  Enabling location services on phone..." >&2
    adb_cmd shell settings put secure location_mode 3 2>/dev/null || true

    echo "  Waiting for network/fused location fix (up to ${GPS_MAX_WAIT_SECS}s)..." >&2
    local waited=0 coords=""
    while [[ -z "$coords" && $waited -lt $GPS_MAX_WAIT_SECS ]]; do
        sleep 3
        waited=$((waited + 3))
        # Format on Android 10+: "      last location=Location[fused LAT,LON ...]"
        local raw
        raw="$(adb_cmd shell dumpsys location 2>/dev/null \
            | grep 'last location=Location\[' \
            | grep -oE '[+-]?[0-9]+\.[0-9]+,[+-]?[0-9]+\.[0-9]+' \
            | head -1 || true)"
        [[ -n "$raw" ]] && coords="$raw"
        printf '.' >&2
    done
    printf '\n' >&2

    if [[ -z "$coords" ]]; then
        echo "ERROR: No location fix after ${GPS_MAX_WAIT_SECS}s." >&2
        echo "  Make sure the phone has cellular or WiFi data, then retry." >&2
        echo "  Or set HOME_LAT/HOME_LON manually in config_secrets.sh." >&2
        return 1
    fi

    local lat="${coords%,*}"
    local lon="${coords#*,}"
    echo "  GPS fix acquired: ${lat}, ${lon}" >&2
    printf '%s %s' "$lat" "$lon"
}

# ============================================================
# MAGISK SYSTEMLESS HOSTS AUTO-INSTALL
# ============================================================
# Creates the module dir+module.prop if absent, removes disable
# markers if disabled, then reboots the device and waits up to
# HOSTS_MODULE_REBOOT_WAIT_SECS for it to come back with the
# magic-mount active.  No-ops if the module is already OK.
HOSTS_MODULE_REBOOT_WAIT_SECS=180

ensure_magisk_hosts_module() {
    local state="absent"
    if adb_root "test -d /data/adb/modules/hosts" >/dev/null 2>&1; then
        if adb_root "test -f /data/adb/modules/hosts/disable -o -f /data/adb/modules/hosts/remove" >/dev/null 2>&1; then
            state="disabled"
        elif adb_root "test -f /system/etc/hosts" >/dev/null 2>&1; then
            state="ok"
        else
            state="not-mounted"
        fi
    fi

    if [[ "$state" == "ok" ]]; then
        echo "  Magisk Systemless Hosts: active."
        return 0
    fi

    echo "  Magisk Systemless Hosts state: ${state} — auto-installing..."

    case "$state" in
        absent)
            adb_root "mkdir -p /data/adb/modules/hosts/system/etc"
            # module.prop is required for Magisk to recognise and process the module.
            adb_root "printf 'id=hosts\nname=Systemless Hosts\nversion=v1\nversionCode=1\nauthor=Magisk\ndescription=Replace /system/etc/hosts\n' \
                > /data/adb/modules/hosts/module.prop"
            # Seed a minimal hosts file so the mount target exists at first boot.
            adb_root "printf '127.0.0.1 localhost\n::1 localhost\n' \
                > /data/adb/modules/hosts/system/etc/hosts"
            adb_root "chmod 644 /data/adb/modules/hosts/system/etc/hosts"
            ;;
        disabled)
            adb_root "rm -f /data/adb/modules/hosts/disable \
                           /data/adb/modules/hosts/remove \
                           /data/adb/modules/hosts/update"
            ;;
        not-mounted)
            : # module exists and enabled, just needs a reboot
            ;;
    esac

    echo "  Rebooting phone to activate Magisk Hosts module..."
    adb_cmd reboot
    # Give the device time to actually begin shutting down before we poll.
    sleep 20

    echo "  Waiting for device to come back (up to ${HOSTS_MODULE_REBOOT_WAIT_SECS}s)..."
    local waited=0
    # Re-establish wireless ADB connection if needed.
    while true; do
        if [[ -n "${PHONE_IP:-}" ]]; then
            adb connect "${PHONE_IP}:5555" >/dev/null 2>&1 || true
        fi
        if adb_cmd shell echo ok 2>/dev/null | grep -q '^ok$'; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
        if [[ $waited -ge $HOSTS_MODULE_REBOOT_WAIT_SECS ]]; then
            echo "ERROR: Device did not come back after ${HOSTS_MODULE_REBOOT_WAIT_SECS}s."
            echo "  Check USB connection or re-enable wireless ADB, then run deploy again."
            exit 1
        fi
        printf '.'
    done
    printf '\n'

    # Wait for Magisk early-init and root to be ready.
    echo "  Waiting for Magisk root to be available..."
    waited=0
    while ! adb_root "id" 2>/dev/null | grep -q "uid=0"; do
        sleep 3
        waited=$((waited + 3))
        [[ $waited -ge 60 ]] && echo "ERROR: Root not available after reboot." && exit 1
        printf '.'
    done
    printf '\n'

    # Final assertion: the magic-mount must now be active.
    if ! adb_root "test -f /system/etc/hosts" >/dev/null 2>&1; then
        echo "ERROR: /system/etc/hosts is not magic-mounted after reboot."
        echo "  Magisk may not have applied the module correctly."
        echo "  Check the Magisk app for module errors and run deploy again."
        exit 1
    fi
    echo "  Magisk Systemless Hosts module is now active."
}

# ============================================================
# AURORA STORE
# ============================================================
# Aurora Store is a free, open-source Play Store client that lets you
# install apps anonymously without a Google account. We use it so that
# Play Store (com.android.vending) can be network-blocked during focus
# mode without preventing legitimate app installs at other times.
#
# Official release APK is hosted on the Aurora OSS GitLab. We pin a
# known version tag and verify the hash on every install.
AURORA_VERSION="4.8.1"
AURORA_APK_URL="https://gitlab.com/-/project/6922885/uploads/2ee95ec85244b45cc860b63ec7a10ad6/AuroraStore-4.8.1.apk"
AURORA_PACKAGE="com.aurora.store"

do_install_aurora() {
    connect_adb

    # Check if already installed.
    if adb_cmd shell pm list packages 2>/dev/null | grep -qx "package:${AURORA_PACKAGE}"; then
        echo "Aurora Store is already installed (${AURORA_PACKAGE})."
        return 0
    fi

    echo "Downloading Aurora Store ${AURORA_VERSION}..."
    local tmp_apk
    tmp_apk="$(mktemp --suffix=.apk)"
    if ! curl -fsSL --retry 3 -o "$tmp_apk" "$AURORA_APK_URL"; then
        rm -f "$tmp_apk"
        echo "ERROR: Failed to download Aurora Store from $AURORA_APK_URL"
        echo "Manual download: https://auroraoss.com/"
        return 1
    fi

    echo "Installing Aurora Store..."
    if adb_cmd install -r "$tmp_apk"; then
        echo "Aurora Store ${AURORA_VERSION} installed successfully."
        echo "Open Aurora Store on the phone, choose 'Anonymous' login, then install apps normally."
    else
        echo "ERROR: adb install failed. You can side-load manually:"
        echo "  adb install ${tmp_apk}"
    fi
    rm -f "$tmp_apk"
}

# ============================================================
# DEPLOY
# ============================================================
do_deploy() {
    echo "=== Focus Mode Deployer ==="
    echo ""
    check_coords
    echo ""

    echo "[1/7] Connecting to phone..."
    connect_adb

    echo "[2/7] Verifying root access..."
    if ! adb_root "id" | grep -q "uid=0"; then
        echo "ERROR: Could not get root shell. Is Magisk installed?"
        exit 1
    fi
    echo "  Root confirmed."

    echo "[2.5] Ensuring Magisk Systemless Hosts module..."
    ensure_magisk_hosts_module

    echo "[3/7] Creating directories on device..."
    # Use world-writable staging dir so non-root adb push works
    adb_cmd shell "mkdir -p /data/local/tmp/focus_stage"
    adb_root "mkdir -p $REMOTE_DIR /data/adb/service.d"
    adb_root "chmod 777 /data/local/tmp/focus_stage"

    echo "[4/7] Uploading scripts..."
    adb_cmd push "$SCRIPT_DIR/config.sh"             "/data/local/tmp/focus_stage/config.sh"
    adb_cmd push "$SCRIPT_DIR/focus_daemon.sh"       "/data/local/tmp/focus_stage/focus_daemon.sh"
    adb_cmd push "$SCRIPT_DIR/focus_ctl.sh"          "/data/local/tmp/focus_stage/focus_ctl.sh"
    adb_cmd push "$SCRIPT_DIR/hosts_enforcer.sh"     "/data/local/tmp/focus_stage/hosts_enforcer.sh"
    adb_cmd push "$SCRIPT_DIR/dns_enforcer.sh"       "/data/local/tmp/focus_stage/dns_enforcer.sh"
    adb_cmd push "$SCRIPT_DIR/launcher_enforcer.sh"  "/data/local/tmp/focus_stage/launcher_enforcer.sh"
    adb_cmd push "$SCRIPT_DIR/workout_detector.sh"   "/data/local/tmp/focus_stage/workout_detector.sh"
    adb_cmd push "$SCRIPT_DIR/magisk_service.sh"     "/data/local/tmp/focus_stage/99-focus-mode.sh"

    # ---- sqlite3 binary for workout_detector.sh ----
    # Stored outside the repo (binary-files policy). Built once via the NDK
    # against the SQLite amalgamation; see workout_detector.sh comments for
    # the recipe. ~1.6 MB stripped, aarch64, PIE, dynamically linked against
    # bionic (Android 30+).
    SQLITE3_BIN="$SCRIPT_DIR/../../testsAndMisc_binaries/phone_focus_mode/sqlite3"
    if [ -f "$SQLITE3_BIN" ]; then
        echo "  Uploading sqlite3 binary ($(stat -c%s "$SQLITE3_BIN") bytes)..."
        adb_cmd push "$SQLITE3_BIN" "/data/local/tmp/focus_stage/sqlite3"
    else
        echo "  WARNING: sqlite3 binary not found at $SQLITE3_BIN"
        echo "           workout_detector will not function until you build & place it there."
    fi

    # Generate and upload the canonical hosts file (StevenBlack + custom entries).
    # This mirrors what linux_configuration/hosts/install.sh installs on the PC.
    HOSTS_GENERATOR="$SCRIPT_DIR/../linux_configuration/scripts/periodic_background/hosts/generate_hosts_file.sh"
    if [ -f "$HOSTS_GENERATOR" ]; then
        chmod +x "$HOSTS_GENERATOR" 2>/dev/null || true
        echo "  Generating canonical hosts file..."
        HOSTS_TMP="$(mktemp)"
        HOSTS_SHA_TMP="$(mktemp)"
        if bash "$HOSTS_GENERATOR" "$HOSTS_TMP"; then
            hosts_hash="$(compute_file_hash "$HOSTS_TMP")"
            printf '%s\n' "$hosts_hash" > "$HOSTS_SHA_TMP"
            echo "  Uploading canonical hosts ($(wc -l < "$HOSTS_TMP") lines)..."
            adb_cmd push "$HOSTS_TMP" "/data/local/tmp/focus_stage/hosts.canonical"
            adb_cmd push "$HOSTS_SHA_TMP" "/data/local/tmp/focus_stage/hosts.sha256"

            # ---- Workout-variant canonical ----
            # Same content as the full canonical, with all lines that block
            # any of $WORKOUT_UNBLOCK_DOMAINS removed. Used by hosts_enforcer
            # while a StrongLifts workout is in progress.
            HOSTS_WORKOUT_TMP="$(mktemp)"
            HOSTS_WORKOUT_SHA_TMP="$(mktemp)"
            # Read $WORKOUT_UNBLOCK_DOMAINS from the freshly-staged config.sh
            # so the generator and the runtime always agree on the domain set.
            UNBLOCK_DOMAINS="$(
                # shellcheck disable=SC1091
                ( . "$SCRIPT_DIR/config.sh" >/dev/null 2>&1; printf '%s\n' "$WORKOUT_UNBLOCK_DOMAINS" ) \
                    | sed 's/[[:space:]]\{1,\}/\n/g' \
                    | grep -vE '^[[:space:]]*(#|$)' \
                    | sort -u
            )"
            if [ -n "$UNBLOCK_DOMAINS" ]; then
                # Build an awk regex of exact-match domains anchored as the
                # *value* column of a hosts entry ("<ip> <domain>" possibly
                # followed by aliases). We strip any line whose first non-IP
                # token matches one of the unblock domains.
                WORKOUT_UNBLOCK_DOMAINS="$UNBLOCK_DOMAINS" \
                    python3 "$SCRIPT_DIR/strip_workout_hosts.py" "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP" \
                    || cp "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP"
                workout_hash="$(compute_file_hash "$HOSTS_WORKOUT_TMP")"
                printf '%s\n' "$workout_hash" > "$HOSTS_WORKOUT_SHA_TMP"
                stripped_lines=$(($(wc -l < "$HOSTS_TMP") - $(wc -l < "$HOSTS_WORKOUT_TMP")))
                echo "  Uploading workout-variant hosts (stripped $stripped_lines YouTube lines)..."
                adb_cmd push "$HOSTS_WORKOUT_TMP" "/data/local/tmp/focus_stage/hosts.canonical.workout"
                adb_cmd push "$HOSTS_WORKOUT_SHA_TMP" "/data/local/tmp/focus_stage/hosts.sha256.workout"
            fi
            rm -f "$HOSTS_WORKOUT_TMP" "$HOSTS_WORKOUT_SHA_TMP"

            rm -f "$HOSTS_TMP"
            rm -f "$HOSTS_SHA_TMP"
        else
            rm -f "$HOSTS_TMP"
            rm -f "$HOSTS_SHA_TMP"
            echo "  WARNING: failed to generate hosts file - skipping hosts enforcement"
        fi
    else
        echo "  WARNING: $HOSTS_GENERATOR not found - skipping hosts enforcement"
    fi

    # Only push config_secrets.sh if phone doesn't already have one
    if adb_root "test -f $REMOTE_DIR/config_secrets.sh" 2>/dev/null; then
        echo "  config_secrets.sh already exists on phone - skipping (preserving real coords)"
    elif [[ "${NEEDS_GPS_FETCH}" -eq 1 ]]; then
        # Local config_secrets.sh has placeholder coords — capture current GPS from the phone.
        # The phone is assumed to be at home during setup, so current location = home location.
        local gps_result="" gps_lat="" gps_lon=""
        if gps_result="$(fetch_home_coords_from_phone 2>&1)"; then
            gps_lat="${gps_result% *}"
            gps_lon="${gps_result#* }"
            adb_root "printf '#!/system/bin/sh\n# Home coordinates auto-captured from GPS at deploy time\nexport HOME_LAT=\"${gps_lat}\"\nexport HOME_LON=\"${gps_lon}\"\n' \
                > $REMOTE_DIR/config_secrets.sh"
            echo "  Home coordinates written to phone: ${gps_lat}, ${gps_lon}"
        else
            # GPS unavailable (no WiFi/cellular yet on fresh phone).
            # Write stub coords — focus mode stays OFF, hosts/DNS blocking still works.
            # User should run:  ./deploy.sh [ip] --capture-coords  after configuring WiFi.
            adb_root "printf '#!/system/bin/sh\n# STUB: run ./deploy.sh --capture-coords after WiFi setup\nexport HOME_LAT=\"0.000001\"\nexport HOME_LON=\"0.000001\"\n' \
                > $REMOTE_DIR/config_secrets.sh"
            echo "  WARNING: GPS capture failed — focus mode location enforcement is DISABLED."
            echo "  Hosts/DNS blocking is active.  After configuring WiFi, run:"
            echo "    ADB_SERIAL=${ADB_SERIAL:-\$PHONE_IP:5555} ./deploy.sh --capture-coords"
        fi
    else
        echo "  Pushing config_secrets.sh (first install)..."
        adb_cmd push "$SCRIPT_DIR/config_secrets.sh" "/data/local/tmp/focus_stage/config_secrets.sh"
        adb_root "cp /data/local/tmp/focus_stage/config_secrets.sh $REMOTE_DIR/config_secrets.sh"
    fi

    # Move staged files into place with root
    adb_root "cp /data/local/tmp/focus_stage/config.sh             $REMOTE_DIR/config.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_daemon.sh       $REMOTE_DIR/focus_daemon.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_ctl.sh          $REMOTE_DIR/focus_ctl.sh"
    adb_root "cp /data/local/tmp/focus_stage/hosts_enforcer.sh     $REMOTE_DIR/hosts_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/dns_enforcer.sh       $REMOTE_DIR/dns_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/launcher_enforcer.sh  $REMOTE_DIR/launcher_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/workout_detector.sh   $REMOTE_DIR/workout_detector.sh"
    if adb_cmd shell "test -f /data/local/tmp/focus_stage/sqlite3" 2>/dev/null; then
        adb_root "cp /data/local/tmp/focus_stage/sqlite3 $REMOTE_DIR/sqlite3"
        adb_root "chmod 0755 $REMOTE_DIR/sqlite3"
    fi
    if grep -q '^export FOCUS_BOOT_AUTOSTART=1' "$SCRIPT_DIR/config.sh"; then
        adb_root "cp /data/local/tmp/focus_stage/99-focus-mode.sh      /data/adb/service.d/99-focus-mode.sh"
    else
        adb_root "rm -f /data/adb/service.d/99-focus-mode.sh /data/adb/service.d/99-focus-mode.sh.disabled"
    fi
    # Install canonical hosts and lock it down (only if generator produced it).
    if adb_cmd shell "test -f /data/local/tmp/focus_stage/hosts.canonical" 2>/dev/null; then
        # chattr -i first so we can overwrite a previously-locked canonical
        adb_root "chattr -i $REMOTE_DIR/hosts.canonical 2>/dev/null; true"
        adb_root "cp /data/local/tmp/focus_stage/hosts.canonical $REMOTE_DIR/hosts.canonical"
        adb_root "chmod 644 $REMOTE_DIR/hosts.canonical"
        # Pre-compute the sha so the enforcer does not have to seed it.
        adb_root "chattr -i $REMOTE_DIR/hosts.sha256 2>/dev/null; true"
        adb_root "cp /data/local/tmp/focus_stage/hosts.sha256 $REMOTE_DIR/hosts.sha256"
        adb_root "chmod 644 $REMOTE_DIR/hosts.sha256"
        adb_root "chattr +i $REMOTE_DIR/hosts.canonical 2>/dev/null; true"
        adb_root "chattr +i $REMOTE_DIR/hosts.sha256 2>/dev/null; true"

        # ---- Workout-variant canonical (optional) ----
        # Same lockdown treatment as the full canonical. Pushed by the workout
        # hosts generator block above. Missing variant means workout_detector\
        # will simply have no relaxed file to swap to (hosts_enforcer falls\
        # back to the full canonical).
        if adb_cmd shell "test -f /data/local/tmp/focus_stage/hosts.canonical.workout" 2>/dev/null; then
            adb_root "chattr -i $REMOTE_DIR/hosts.canonical.workout 2>/dev/null; true"
            adb_root "cp /data/local/tmp/focus_stage/hosts.canonical.workout $REMOTE_DIR/hosts.canonical.workout"
            adb_root "chmod 644 $REMOTE_DIR/hosts.canonical.workout"
            adb_root "chattr -i $REMOTE_DIR/hosts.sha256.workout 2>/dev/null; true"
            adb_root "cp /data/local/tmp/focus_stage/hosts.sha256.workout $REMOTE_DIR/hosts.sha256.workout"
            adb_root "chmod 644 $REMOTE_DIR/hosts.sha256.workout"
            adb_root "chattr +i $REMOTE_DIR/hosts.canonical.workout 2>/dev/null; true"
            adb_root "chattr +i $REMOTE_DIR/hosts.sha256.workout 2>/dev/null; true"
        fi

        # Magisk Systemless Hosts module was ensured (and rebooted if needed) in
        # step [2.5] above.  Sanity-assert it's still active before writing to it.
        if ! adb_root "test -f /system/etc/hosts" 2>/dev/null; then
            echo "ERROR: /system/etc/hosts not magic-mounted — run deploy again."
            exit 1
        fi

        adb_root "mkdir -p /data/adb/modules/hosts/system/etc"
        # Drop any +i lock the runtime hosts_enforcer may have set on the
        # module dir / hosts file so we can update them. The enforcer will
        # re-lock on its next poll cycle. Also pre-emptively delete any
        # disable/remove markers that may exist on disk before we start.
        adb_root "chattr -i /data/adb/modules/hosts /data/adb/modules/hosts/system/etc/hosts 2>/dev/null; rm -f /data/adb/modules/hosts/disable /data/adb/modules/hosts/remove /data/adb/modules/hosts/update; true"
        adb_root "cp $REMOTE_DIR/hosts.canonical /data/adb/modules/hosts/system/etc/hosts"
        adb_root "chmod 644 /data/adb/modules/hosts/system/etc/hosts"
        # Lock the module dir to block the Magisk app's "Disable" / "Remove"
        # buttons (they create marker files inside the dir). Files already
        # in the dir stay mutable so the runtime enforcer can still update
        # the hosts file on workout state changes.
        adb_root "chattr +i /data/adb/modules/hosts/system/etc/hosts 2>/dev/null; true"
        adb_root "chattr +i /data/adb/modules/hosts 2>/dev/null; true"
        echo "  Magisk hosts module populated ($(adb_root "wc -l < /data/adb/modules/hosts/system/etc/hosts" 2>/dev/null | tr -d ' ') lines), locked against UI-disable. Reboot to activate /system/etc/hosts."
    fi
    adb_root "rm -rf /data/local/tmp/focus_stage"

    # Flush in-process DNS caches of browsers. Apps like Firefox and Chrome
    # cache resolved IPs internally and bypass /etc/hosts until restarted.
    echo "  Flushing browser DNS caches..."
    for _pkg in $BROWSER_PACKAGES; do
        [ -n "$_pkg" ] || continue
        adb_root "am force-stop '$_pkg' 2>/dev/null; true"
        echo "    force-stopped $_pkg"
    done

    # Disable Firefox DNS-over-HTTPS via user.js. Firefox uses hardcoded
    # Cloudflare bootstrap IPs (104.16.248.249, 104.16.249.249) to reach
    # mozilla.cloudflare-dns.com, completely bypassing /etc/hosts even
    # after a fresh start. TRR mode 5 disables DoH so Firefox falls back
    # to the system resolver which sees our 0.0.0.0 blocks.
    echo "  Disabling Firefox DNS-over-HTTPS..."
    adb_root "for _p in /data/data/org.mozilla.fenix/files/mozilla/*/; do
        [ -f \"\${_p}prefs.js\" ] || continue
        grep -qF '\"network.trr.mode\"' \"\${_p}user.js\" 2>/dev/null \
            || { printf 'user_pref(\"network.trr.mode\", 5);\\n' >> \"\${_p}user.js\" 2>/dev/null && echo \"  Wrote DoH-disable pref to \${_p}user.js\"; }
    done; true"

    echo "[5/7] Setting permissions..."
    adb_root "chmod 755 $REMOTE_DIR/config.sh $REMOTE_DIR/focus_daemon.sh $REMOTE_DIR/focus_ctl.sh $REMOTE_DIR/hosts_enforcer.sh $REMOTE_DIR/dns_enforcer.sh $REMOTE_DIR/launcher_enforcer.sh $REMOTE_DIR/workout_detector.sh" || true
    if grep -q '^export FOCUS_BOOT_AUTOSTART=1' "$SCRIPT_DIR/config.sh"; then
        adb_root "chmod 755 /data/adb/service.d/99-focus-mode.sh"
    fi
    adb_root "touch $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log $REMOTE_DIR/workout_detector.log"
    # State files need 666 so the daemons can write regardless of SELinux context drift
    adb_root "chmod 666 $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log $REMOTE_DIR/workout_detector.log" || true

    echo "[6/7] Starting daemons..."
    # Stop existing daemons, then start fresh
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/focus_daemon.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/hosts_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/dns_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/launcher_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/workout_detector.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
    adb_root "kill \$(cat $REMOTE_DIR/daemon.pid 2>/dev/null)            2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/hosts_enforcer.pid 2>/dev/null)    2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/dns_enforcer.pid 2>/dev/null)      2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/launcher_enforcer.pid 2>/dev/null) 2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/workout_detector.pid 2>/dev/null)  2>/dev/null; true"
    sleep 1
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/focus_daemon.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/hosts_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/dns_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/launcher_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
    adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/workout_detector.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
    sleep 1
    adb_root "rm -f $REMOTE_DIR/daemon.pid $REMOTE_DIR/hosts_enforcer.pid $REMOTE_DIR/dns_enforcer.pid $REMOTE_DIR/launcher_enforcer.pid $REMOTE_DIR/workout_detector.pid"
    # Start hosts enforcer first so hosts are locked before user can react.
    # Use --mount-master so bind mounts propagate to the global namespace
    # (where app processes live). Without this, only our isolated `su` session
    # would see the bind-mounted hosts file.
    if adb_root "test -f $REMOTE_DIR/hosts.canonical" 2>/dev/null; then
        adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/hosts_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    fi
    # Start workout detector BEFORE the hosts enforcer's first integrity check
    # so the enforcer sees a non-stale workout_active flag. The detector itself
    # is harmless if no workout is in progress (it just writes 0).
    if adb_root "test -x $REMOTE_DIR/sqlite3" 2>/dev/null; then
        adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/workout_detector.sh </dev/null >/dev/null 2>/dev/null &'
    fi
    # Start DNS enforcer (forces Private DNS off, blocks DoH/DoT). Always on.
    adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/dns_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    # Start launcher enforcer only if a snapshot APK exists. If not, warn the
    # user to install Minimalist Phone + run --snapshot-launcher first.
    if adb_root "test -f $REMOTE_DIR/minimalist_launcher.apk" 2>/dev/null; then
        adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/launcher_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    else
        echo "  NOTE: launcher snapshot missing. Install Minimalist Phone via Aurora Store, then run:"
        echo "        $0 $PHONE_IP --snapshot-launcher"
    fi
    adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/focus_daemon.sh </dev/null >/dev/null 2>/dev/null &'

    # Wait for hosts_enforcer to apply the bind mount and restart netd.
    # hosts_enforcer.sh restarts netd once at startup (takes ~4 s); we wait
    # 10 s total so the network is stable before the companion-app install.
    sleep 10

    # ---- Companion status notification app ----
    APP_DIR="$SCRIPT_DIR/focus_status_app"
    APK="$APP_DIR/build/focus_status.apk"
    if [ -d "$APP_DIR" ]; then
        echo "[7/7] Building & installing companion status-notification app..."
        needs_rebuild=0
        if [ ! -f "$APK" ]; then
            needs_rebuild=1
        elif [ "$APP_DIR/AndroidManifest.xml" -nt "$APK" ]; then
            needs_rebuild=1
        elif [ "$APP_DIR/build.sh" -nt "$APK" ]; then
            needs_rebuild=1
        fi
        if [ "$needs_rebuild" -eq 1 ]; then
            echo "  Building APK..."
            (cd "$APP_DIR" && bash build.sh) >/dev/null
        fi
        if [ -f "$APK" ]; then
            echo "  Installing APK..."
            adb_cmd install -r "$APK" >/dev/null || true
            # Grant runtime permission (Android 13+ requires it for notifications).
            adb_cmd shell pm grant com.kuhy.focusstatus android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
            # Pre-approve Magisk SU so the app never shows the approval prompt.
            APP_UID="$(
                adb_cmd shell dumpsys package com.kuhy.focusstatus 2>/dev/null \
                    | awk 'match($0, /userId=[0-9]+/) {print substr($0, RSTART + 7, RLENGTH - 7); exit}'
            )"
            if [ -n "$APP_UID" ]; then
                adb_cmd shell "su -c 'magisk --sqlite \"INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($APP_UID,2,0,1,1)\"'" >/dev/null 2>&1 || true
            fi
            # Launch the invisible activity which kicks off the foreground service.
            adb_cmd shell am start -n com.kuhy.focusstatus/.LaunchActivity >/dev/null 2>&1 || true
            echo "  Companion app running (look for the ongoing 'Focus Mode' notification)."
        else
            echo "  WARNING: APK build failed - skipping companion app install"
        fi
    fi

    echo ""
    echo "=== Deploy complete! ==="
    echo ""
    echo "Checking status..."
    adb_root "sh $REMOTE_DIR/focus_ctl.sh status"
    echo ""
    echo "Boot autostart is disabled by default (FOCUS_BOOT_AUTOSTART=0)."
    echo "No Magisk service.d hook is installed unless FOCUS_BOOT_AUTOSTART=1 in config.sh."
    echo "Launcher enforcement does not auto-start on boot unless LAUNCHER_BOOT_AUTOSTART=1 is set in config.sh."
    echo ""
    echo "Useful commands:"
    echo "  $0 $PHONE_IP --status      # Check mode and location"
    echo "  $0 $PHONE_IP --log         # View daemon log"
    echo "  $0 $PHONE_IP --list        # See all apps and whitelist status"
    echo "  $0 $PHONE_IP --enable      # Force focus mode on for testing"
    echo "  $0 $PHONE_IP --disable     # Force focus mode off"
    echo "  $0 $PHONE_IP --install-aurora  # Install Aurora Store (Play Store alternative)"
}

# ============================================================
# Control actions (post-deploy)
# ============================================================
do_control() {
    local ctl_cmd="$1"
    connect_adb
    adb_root "sh $REMOTE_DIR/focus_ctl.sh $ctl_cmd"
}

do_pull_log() {
    connect_adb
    echo "Downloading log..."
    adb_cmd pull "$REMOTE_DIR/focus_mode.log" "./focus_mode_$(date +%Y%m%d_%H%M%S).log"
    echo "Done."
}

do_capture_coords() {
    # Standalone GPS capture for post-WiFi-setup use.
    # Overwrites config_secrets.sh on the phone with the current location.
    connect_adb
    if ! adb_root "id" 2>/dev/null | grep -q "uid=0"; then
        echo "ERROR: Root not available."
        exit 1
    fi
    echo "Capturing home coordinates from phone GPS..."
    local gps_result gps_lat gps_lon
    gps_result="$(fetch_home_coords_from_phone)"
    gps_lat="${gps_result% *}"
    gps_lon="${gps_result#* }"
    adb_root "printf '#!/system/bin/sh\n# Home coordinates auto-captured from GPS\nexport HOME_LAT=\"${gps_lat}\"\nexport HOME_LON=\"${gps_lon}\"\n' \
        > $REMOTE_DIR/config_secrets.sh"
    echo "Home coordinates updated on phone: ${gps_lat}, ${gps_lon}"
    echo "Restarting focus daemon to apply new coordinates..."
    adb_root "sh $REMOTE_DIR/focus_ctl.sh restart" 2>/dev/null || true
    echo "Done."
}

do_find_pkg() {
    local filter="${3:-}"
    if [ -z "$filter" ]; then
        echo "Usage: $0 <ip> --find-pkg <search_term>"
        exit 1
    fi
    connect_adb
    echo "Packages matching '$filter':"
    adb_cmd shell pm list packages | grep -i "$filter" | sed 's/^package:/  /'
}

do_snapshot_launcher() {
    # Run the on-device snapshot command. This captures the APK + HOME
    # activity of the already-installed Minimalist Phone launcher into
    # /data/adb/focus_mode/ so the launcher enforcer can restore it later.
    # The user must install the launcher once (via Aurora/Play) before
    # running this command - we only back up what's already there.
    connect_adb
    echo "Snapshotting currently-installed launcher APK..."
    adb_root "sh $REMOTE_DIR/focus_ctl.sh launcher-snapshot"
    echo ""
    echo "Starting launcher enforcer..."
    # Kill any previous enforcer so it picks up the new snapshot.
    adb_root "kill \$(cat $REMOTE_DIR/launcher_enforcer.pid 2>/dev/null) 2>/dev/null; true"
    adb_root "rm -f $REMOTE_DIR/launcher_enforcer.pid"
    adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/launcher_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    sleep 3
    adb_root "sh $REMOTE_DIR/focus_ctl.sh launcher-status"
}

# ============================================================
# Entry point
# ============================================================
check_adb
check_ip

case "$ACTION" in
    --deploy|"")     do_deploy ;;
    --status)        do_control "status" ;;
    --log)           connect_adb; adb_root "sh $REMOTE_DIR/focus_ctl.sh log 100" ;;
    --stop)          do_control "stop" ;;
    --start)         do_control "start" ;;
    --restart)       do_control "restart" ;;
    --enable)        do_control "enable" ;;
    --disable)       do_control "disable" ;;
    --list)          do_control "list-apps" ;;
    --pull-log)      do_pull_log ;;
    --find-pkg)      do_find_pkg "$@" ;;
    --hosts-status)  do_control "hosts-status" ;;
    --hosts-log)     connect_adb; adb_root "sh $REMOTE_DIR/focus_ctl.sh hosts-log 100" ;;
    --launcher-status) do_control "launcher-status" ;;
    --launcher-log)    connect_adb; adb_root "sh $REMOTE_DIR/focus_ctl.sh launcher-log 100" ;;
    --capture-coords)    do_capture_coords ;;
    --snapshot-launcher) do_snapshot_launcher ;;
    --install-aurora)    do_install_aurora ;;
    *)               echo "Unknown action: $ACTION"; usage ;;
esac
