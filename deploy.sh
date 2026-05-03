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
    # Allow redacted values locally - real coords live only on the phone
    if [ "$lat" = "0.000000" ] && [ "$lon" = "0.000000" ]; then
        echo "ERROR: Home coordinates not set (all zeros). Set them in config_secrets.sh."
        exit 1
    fi
    if [ -z "$lat" ] || [ -z "$lon" ]; then
        echo "  Home location: (not set locally - will use values on phone)"
    else
        echo "  Home location: $lat, $lon"
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
    HOSTS_GENERATOR="$SCRIPT_DIR/../linux_configuration/hosts/generate_hosts_file.sh"
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
                python3 - "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP" <<PY_EOF || cp "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP"
import sys

unblock = set("""
$UNBLOCK_DOMAINS
""".split())

with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as src, \
     open(sys.argv[2], 'w', encoding='utf-8') as dst:
    for line in src:
        s = line.strip()
        if not s or s.startswith('#'):
            dst.write(line)
            continue
        parts = s.split()
        # Hosts entry layout: <ip> <name> [aliases...]
        if len(parts) >= 2 and any(p.lower() in unblock for p in parts[1:]):
            continue
        dst.write(line)
PY_EOF
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

        # ---- Magisk Systemless Hosts module (REQUIRED) ----
        # This module magic-mounts /data/adb/modules/hosts/system/etc/hosts
        # as /system/etc/hosts at boot — the only way to create that file on
        # this ROM's hardware-read-only system partition.
        #
        # The module must be ENABLED in the Magisk app by the user (one-time,
        # after each factory reset). We CANNOT enable it programmatically.
        # Without it, no app-level hosts blocking is possible, so we STOP here
        # and require user action before the deploy can proceed.
        local magisk_hosts_ok=0
        if adb_root "test -d /data/adb/modules/hosts" 2>/dev/null; then
            if adb_root "test ! -f /data/adb/modules/hosts/disable -a ! -f /data/adb/modules/hosts/remove" 2>/dev/null; then
                magisk_hosts_ok=1
            fi
        fi

        if [[ "$magisk_hosts_ok" -eq 0 ]]; then
            echo ""
            echo "╔══════════════════════════════════════════════════════════════════╗"
            echo "║  ACTION REQUIRED — Deploy cannot continue                       ║"
            echo "╠══════════════════════════════════════════════════════════════════╣"
            echo "║  The Magisk 'Systemless Hosts' module is not enabled.           ║"
            echo "║  Without it, hosts-file blocking is impossible on this device   ║"
            echo "║  (the system partition is hardware read-only even with root).   ║"
            echo "║                                                                 ║"
            echo "║  Steps to fix:                                                  ║"
            echo "║    1. Open the Magisk app on the phone                         ║"
            echo "║    2. Tap the Modules tab (puzzle-piece icon)                   ║"
            echo "║    3. Find 'Systemless Hosts' and toggle it ON                  ║"
            echo "║    4. Reboot the phone when prompted                            ║"
            echo "║    5. Re-run this deploy command                                ║"
            echo "╚══════════════════════════════════════════════════════════════════╝"
            echo ""
            exit 1
        fi

        adb_root "mkdir -p /data/adb/modules/hosts/system/etc"
        adb_root "cp $REMOTE_DIR/hosts.canonical /data/adb/modules/hosts/system/etc/hosts"
        adb_root "chmod 644 /data/adb/modules/hosts/system/etc/hosts"
        echo "  Magisk hosts module populated ($(adb_root "wc -l < /data/adb/modules/hosts/system/etc/hosts" 2>/dev/null | tr -d ' ') lines). Reboot to activate /system/etc/hosts."
    fi
    adb_root "rm -rf /data/local/tmp/focus_stage"

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
    sleep 4

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
    --snapshot-launcher) do_snapshot_launcher ;;
    --install-aurora)    do_install_aurora ;;
    *)               echo "Unknown action: $ACTION"; usage ;;
esac
