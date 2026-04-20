#!/bin/sh
# ============================================================
# Magisk service.d autostart script
# This file is placed on the device at:
#   /data/adb/service.d/99-focus-mode.sh
# Magisk executes everything in service.d on boot with root.
# ============================================================

# Wait for system to be fully booted before starting daemons
sleep 120

SCRIPT_DIR="/data/local/tmp/focus_mode"

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/focus_daemon.sh"
chmod +x "$SCRIPT_DIR/focus_ctl.sh"
chmod +x "$SCRIPT_DIR/hosts_enforcer.sh"
chmod +x "$SCRIPT_DIR/dns_enforcer.sh"
chmod +x "$SCRIPT_DIR/launcher_enforcer.sh"

# Start hosts enforcer FIRST - it must bind-mount the hosts file before
# the user has a chance to exploit it. This runs even outside focus mode
# because hosts hardening should always be active.
setsid sh "$SCRIPT_DIR/hosts_enforcer.sh" </dev/null >/dev/null 2>&1 &

# Start DNS enforcer - forces Private DNS off and blocks DoH/DoT endpoints
# so the hosts file actually gets consulted by apps that would otherwise
# bypass it (e.g. Chrome's built-in secure DNS). Always on.
setsid sh "$SCRIPT_DIR/dns_enforcer.sh" </dev/null >/dev/null 2>&1 &

# Start launcher enforcer - keeps Minimalist Phone installed and pinned as
# the default HOME. Always on (not location-gated).
setsid sh "$SCRIPT_DIR/launcher_enforcer.sh" </dev/null >/dev/null 2>&1 &

# Start focus daemon in a new session (detached from any controlling terminal)
setsid sh "$SCRIPT_DIR/focus_daemon.sh" </dev/null >/dev/null 2>&1 &

exit 0
