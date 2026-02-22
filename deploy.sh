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
    lat="$(grep '^HOME_LAT=' "$SCRIPT_DIR/config.sh" | cut -d'"' -f2)"
    lon="$(grep '^HOME_LON=' "$SCRIPT_DIR/config.sh" | cut -d'"' -f2)"
    if [ "$lat" = "0.000000" ] && [ "$lon" = "0.000000" ]; then
        echo "ERROR: You must set your home coordinates in config.sh before deploying!"
        echo ""
        echo "  1. Find your coords on Google Maps (right-click your apartment)"
        echo "  2. Edit phone_focus_mode/config.sh:"
        echo "       HOME_LAT=\"52.123456\""
        echo "       HOME_LON=\"21.098765\""
        exit 1
    fi
    echo "  Home location: $lat, $lon"
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

# Wrapper: run a root shell command on the phone
adb_root() {
    adb -s "$PHONE_IP:5555" shell su -c "$1"
}

# ============================================================
# DEPLOY
# ============================================================
do_deploy() {
    echo "=== Focus Mode Deployer ==="
    echo ""
    check_coords
    echo ""

    echo "[1/6] Connecting to phone..."
    connect_adb

    echo "[2/6] Verifying root access..."
    if ! adb_root "id" | grep -q "uid=0"; then
        echo "ERROR: Could not get root shell. Is Magisk installed?"
        exit 1
    fi
    echo "  Root confirmed."

    echo "[3/6] Creating directories on device..."
    # Use world-writable staging dir so non-root adb push works
    adb -s "$PHONE_IP:5555" shell "mkdir -p /data/local/tmp/focus_stage"
    adb_root "mkdir -p $REMOTE_DIR /data/adb/service.d"
    adb_root "chmod 777 /data/local/tmp/focus_stage"

    echo "[4/6] Uploading scripts..."
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/config.sh"         "/data/local/tmp/focus_stage/config.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/focus_daemon.sh"   "/data/local/tmp/focus_stage/focus_daemon.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/focus_ctl.sh"      "/data/local/tmp/focus_stage/focus_ctl.sh"
    adb -s "$PHONE_IP:5555" push "$SCRIPT_DIR/magisk_service.sh" "/data/local/tmp/focus_stage/99-focus-mode.sh"

    # Move staged files into place with root
    adb_root "cp /data/local/tmp/focus_stage/config.sh         $REMOTE_DIR/config.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_daemon.sh   $REMOTE_DIR/focus_daemon.sh"
    adb_root "cp /data/local/tmp/focus_stage/focus_ctl.sh      $REMOTE_DIR/focus_ctl.sh"
    adb_root "cp /data/local/tmp/focus_stage/99-focus-mode.sh  /data/adb/service.d/99-focus-mode.sh"
    adb_root "rm -rf /data/local/tmp/focus_stage"

    echo "[5/6] Setting permissions..."
    adb_root "chmod 755 $REMOTE_DIR/config.sh $REMOTE_DIR/focus_daemon.sh $REMOTE_DIR/focus_ctl.sh"
    adb_root "chmod 755 /data/adb/service.d/99-focus-mode.sh"
    adb_root "touch $REMOTE_DIR/disabled_by_focus.txt"
    adb_root "touch $REMOTE_DIR/focus_mode.log"

    echo "[6/6] Starting daemon..."
    # Kill existing daemon via pidfile to avoid hitting the ADB shell process
    adb_root "
        PIDFILE=$REMOTE_DIR/daemon.pid
        if [ -f \"\$PIDFILE\" ]; then
            OLD_PID=\$(cat \"\$PIDFILE\")
            kill -9 \"\$OLD_PID\" 2>/dev/null
            rm -f \"\$PIDFILE\"
        fi
        # Also kill any stray instances
        for p in \$(pgrep -f focus_daemon.sh 2>/dev/null); do kill -9 \$p 2>/dev/null; done
        sleep 1
        setsid sh $REMOTE_DIR/focus_daemon.sh </dev/null >/dev/null 2>&1 &
        echo \$!
    "
    sleep 3

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
    *)               echo "Unknown action: $ACTION"; usage ;;
esac
