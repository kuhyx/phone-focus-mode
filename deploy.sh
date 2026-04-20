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

usage() {
    echo "Usage: $0 <phone_ip> [action]"
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
    if [ -z "$PHONE_IP" ]; then
        echo "ERROR: Phone IP not provided."
        echo ""
        usage
    fi
}

connect_adb() {
    echo "Connecting to $PHONE_IP:5555 ..."
    adb connect "$PHONE_IP:5555"
    sleep 1
    if ! adb devices | grep -q "$PHONE_IP"; then
        echo "ERROR: Could not connect to $PHONE_IP:5555"
        echo "Make sure wireless ADB is enabled and the phone is reachable."
        exit 1
    fi
    echo "Connected."
}

# Wrapper: run a root shell command on the phone.
# Uses --mount-master so the command sees (and can modify) the global mount
# namespace — required for any status checks that inspect the hosts bind
# mount, /data/adb/focus_mode files, or for starting daemons.
adb_root() {
    adb -s "$PHONE_IP:5555" shell su --mount-master -c "$1"
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
    adb -s "$PHONE_IP:5555" shell "mkdir -p /data/local/tmp/focus_stage"
    adb_root "mkdir -p $REMOTE_DIR /data/adb/service.d /data/adb/focus_mode"
    adb_root "chmod 777 /data/local/tmp/focus_stage"

    echo "[4/7] Uploading scripts..."
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/config.sh"             "/data/local/tmp/focus_stage/config.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/focus_daemon.sh"       "/data/local/tmp/focus_stage/focus_daemon.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/focus_ctl.sh"          "/data/local/tmp/focus_stage/focus_ctl.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/hosts_enforcer.sh"     "/data/local/tmp/focus_stage/hosts_enforcer.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/dns_enforcer.sh"       "/data/local/tmp/focus_stage/dns_enforcer.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/launcher_enforcer.sh"  "/data/local/tmp/focus_stage/launcher_enforcer.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/magisk_service.sh"     "/data/local/tmp/focus_stage/99-focus-mode.sh"

    # Generate and upload the canonical hosts file (StevenBlack + custom entries).
    # This mirrors what linux_configuration/hosts/install.sh installs on the PC.
    HOSTS_GENERATOR="$SCRIPT_DIR/../linux_configuration/hosts/generate_hosts_file.sh"
    if [ -f "$HOSTS_GENERATOR" ]; then
        chmod +x "$HOSTS_GENERATOR" 2>/dev/null || true
        echo "  Generating canonical hosts file..."
        HOSTS_TMP="$(mktemp)"
        if bash "$HOSTS_GENERATOR" "$HOSTS_TMP"; then
            echo "  Uploading canonical hosts ($(wc -l < "$HOSTS_TMP") lines)..."
            adb -s "$PHONE_IP:5555" push "$HOSTS_TMP" "/data/local/tmp/focus_stage/hosts.canonical"
            rm -f "$HOSTS_TMP"
        else
            rm -f "$HOSTS_TMP"
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
        adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/config_secrets.sh" "/data/local/tmp/focus_stage/config_secrets.sh"
        adb_root "cp /data/local/tmp/focus_stage/config_secrets.sh $REMOTE_DIR/config_secrets.sh"
    fi

    # Move staged files into place with root
    adb_root "cp /data/local/tmp/focus_stage/config.sh             $REMOTE_DIR/config.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_daemon.sh       $REMOTE_DIR/focus_daemon.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_ctl.sh          $REMOTE_DIR/focus_ctl.sh"
    adb_root "cp /data/local/tmp/focus_stage/hosts_enforcer.sh     $REMOTE_DIR/hosts_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/dns_enforcer.sh       $REMOTE_DIR/dns_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/launcher_enforcer.sh  $REMOTE_DIR/launcher_enforcer.sh"
    adb_root "cp /data/local/tmp/focus_stage/99-focus-mode.sh      /data/adb/service.d/99-focus-mode.sh"
    # Install canonical hosts and lock it down (only if generator produced it).
    if adb -s "$PHONE_IP:5555" shell "test -f /data/local/tmp/focus_stage/hosts.canonical" 2>/dev/null; then
        # chattr -i first so we can overwrite a previously-locked canonical
        adb_root "chattr -i /data/adb/focus_mode/hosts.canonical 2>/dev/null; true"
        adb_root "cp /data/local/tmp/focus_stage/hosts.canonical /data/adb/focus_mode/hosts.canonical"
        adb_root "chmod 644 /data/adb/focus_mode/hosts.canonical"
        # Pre-compute the sha so the enforcer does not have to seed it.
        adb_root "chattr -i /data/adb/focus_mode/hosts.sha256 2>/dev/null; true"
        adb_root "sha256sum /data/adb/focus_mode/hosts.canonical | awk '{print \$1}' > /data/adb/focus_mode/hosts.sha256 2>/dev/null || md5sum /data/adb/focus_mode/hosts.canonical | awk '{print \$1}' > /data/adb/focus_mode/hosts.sha256"
        adb_root "chmod 644 /data/adb/focus_mode/hosts.sha256"
        adb_root "chattr +i /data/adb/focus_mode/hosts.canonical 2>/dev/null; true"
        adb_root "chattr +i /data/adb/focus_mode/hosts.sha256 2>/dev/null; true"
    fi
    adb_root "rm -rf /data/local/tmp/focus_stage"

    echo "[5/7] Setting permissions..."
    adb_root "chmod 755 $REMOTE_DIR/config.sh $REMOTE_DIR/focus_daemon.sh $REMOTE_DIR/focus_ctl.sh $REMOTE_DIR/hosts_enforcer.sh $REMOTE_DIR/dns_enforcer.sh $REMOTE_DIR/launcher_enforcer.sh" || true
    adb_root "chmod 755 /data/adb/service.d/99-focus-mode.sh"
    adb_root "touch $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log"
    # State files need 666 so the daemons can write regardless of SELinux context drift
    adb_root "chmod 666 $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log" || true

    echo "[6/7] Starting daemons..."
    # Stop existing daemons, then start fresh
    adb_root "kill \$(cat $REMOTE_DIR/daemon.pid 2>/dev/null)            2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/hosts_enforcer.pid 2>/dev/null)    2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/dns_enforcer.pid 2>/dev/null)      2>/dev/null; true"
    adb_root "kill \$(cat $REMOTE_DIR/launcher_enforcer.pid 2>/dev/null) 2>/dev/null; true"
    sleep 1
    adb_root "rm -f $REMOTE_DIR/daemon.pid $REMOTE_DIR/hosts_enforcer.pid $REMOTE_DIR/dns_enforcer.pid $REMOTE_DIR/launcher_enforcer.pid"
    # Start hosts enforcer first so hosts are locked before user can react.
    # Use --mount-master so bind mounts propagate to the global namespace
    # (where app processes live). Without this, only our isolated `su` session
    # would see the bind-mounted hosts file.
    if adb_root "test -f /data/adb/focus_mode/hosts.canonical" 2>/dev/null; then
        adb -s "$PHONE_IP:5555" shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/hosts_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    fi
    # Start DNS enforcer (forces Private DNS off, blocks DoH/DoT). Always on.
    adb -s "$PHONE_IP:5555" shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/dns_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    # Start launcher enforcer only if a snapshot APK exists. If not, warn the
    # user to install Minimalist Phone + run --snapshot-launcher first.
    if adb_root "test -f /data/adb/focus_mode/minimalist_launcher.apk" 2>/dev/null; then
        adb -s "$PHONE_IP:5555" shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/launcher_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
    else
        echo "  NOTE: launcher snapshot missing. Install Minimalist Phone via Aurora Store, then run:"
        echo "        $0 $PHONE_IP --snapshot-launcher"
    fi
    adb -s "$PHONE_IP:5555" shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/focus_daemon.sh </dev/null >/dev/null 2>/dev/null &'
    sleep 4

    # ---- Companion status notification app ----
    APP_DIR="$SCRIPT_DIR/focus_status_app"
    APK="$APP_DIR/build/focus_status.apk"
    if [ -d "$APP_DIR" ]; then
        echo "[7/7] Building & installing companion status-notification app..."
        if [ ! -f "$APK" ] || [ "$APP_DIR/AndroidManifest.xml" -nt "$APK" ] || [ "$APP_DIR/build.sh" -nt "$APK" ]; then
            echo "  Building APK..."
            (cd "$APP_DIR" && bash build.sh) >/dev/null
        fi
        if [ -f "$APK" ]; then
            echo "  Installing APK..."
            adb -s "$PHONE_IP:5555" install -r "$APK" >/dev/null || true
            # Grant runtime permission (Android 13+ requires it for notifications).
            adb -s "$PHONE_IP:5555" shell pm grant com.kuhy.focusstatus android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
            # Pre-approve Magisk SU so the app never shows the approval prompt.
            APP_UID="$(adb -s "$PHONE_IP:5555" shell dumpsys package com.kuhy.focusstatus 2>/dev/null | grep -oE 'userId=[0-9]+' | head -1 | cut -d= -f2)"
            if [ -n "$APP_UID" ]; then
                adb -s "$PHONE_IP:5555" shell "su -c 'magisk --sqlite \"INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($APP_UID,2,0,1,1)\"'" >/dev/null 2>&1 || true
            fi
            # Launch the invisible activity which kicks off the foreground service.
            adb -s "$PHONE_IP:5555" shell am start -n com.kuhy.focusstatus/.LaunchActivity >/dev/null 2>&1 || true
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
    echo "The daemon will auto-start on every boot via Magisk service.d."
    echo ""
    echo "Useful commands:"
    echo "  $0 $PHONE_IP --status      # Check mode and location"
    echo "  $0 $PHONE_IP --log         # View daemon log"
    echo "  $0 $PHONE_IP --list        # See all apps and whitelist status"
    echo "  $0 $PHONE_IP --enable      # Force focus mode on for testing"
    echo "  $0 $PHONE_IP --disable     # Force focus mode off"
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
    adb -s "$PHONE_IP:5555" pull "$REMOTE_DIR/focus_mode.log" "./focus_mode_$(date +%Y%m%d_%H%M%S).log"
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
    adb -s "$PHONE_IP:5555" shell pm list packages | grep -i "$filter" | sed 's/^package:/  /'
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
    adb -s "$PHONE_IP:5555" shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/launcher_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
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
    *)               echo "Unknown action: $ACTION"; usage ;;
esac
