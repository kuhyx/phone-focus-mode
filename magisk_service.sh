#!/bin/sh
# ============================================================
# Magisk service.d autostart script
# This file is placed on the device at:
#   /data/adb/service.d/99-focus-mode.sh
# Magisk executes everything in service.d on boot with root.
# ============================================================

# Wait for system to be fully booted before starting daemon
sleep 120

SCRIPT_DIR="/data/local/tmp/focus_mode"

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/focus_daemon.sh"
chmod +x "$SCRIPT_DIR/focus_ctl.sh"

# Start focus daemon in a new session (detached from any controlling terminal)
setsid sh "$SCRIPT_DIR/focus_daemon.sh" </dev/null >/dev/null 2>&1 &

exit 0
