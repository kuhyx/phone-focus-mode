#!/system/bin/sh
# shellcheck shell=ash
# ============================================================
# Focus Mode Control Utility
# Run on the phone via: su --mount-master -c /data/local/tmp/focus_mode/focus_ctl.sh <command>
# Or from PC via: adb shell su --mount-master -c '/data/local/tmp/focus_mode/focus_ctl.sh <command>'
# --mount-master is required so this script (and any daemon it spawns) joins
# the global mount namespace; otherwise the hosts bind mount is invisible and
# /data/adb/focus_mode/* checks fail due to per-session SELinux isolation.
# ============================================================

SCRIPT_DIR="/data/local/tmp/focus_mode"
. "$SCRIPT_DIR/config.sh"
# shellcheck source=ctl_hosts.sh
. "$SCRIPT_DIR/ctl_hosts.sh"
# shellcheck source=ctl_dns.sh
. "$SCRIPT_DIR/ctl_dns.sh"
# shellcheck source=ctl_launcher.sh
. "$SCRIPT_DIR/ctl_launcher.sh"
# shellcheck source=ctl_workout.sh
. "$SCRIPT_DIR/ctl_workout.sh"
# shellcheck source=ctl_curfew.sh
. "$SCRIPT_DIR/ctl_curfew.sh"
# shellcheck source=ctl_tether.sh
. "$SCRIPT_DIR/ctl_tether.sh"
# shellcheck source=ctl_usage.sh
. "$SCRIPT_DIR/ctl_usage.sh"
# shellcheck source=ctl_daemon.sh
. "$SCRIPT_DIR/ctl_daemon.sh"


# ---- Logging ----
log() {
	local ts
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$ts] $1" >>"$LOG_FILE"
}














HOSTS_PIDFILE="$STATE_DIR/hosts_enforcer.pid"






# ---- DNS enforcer ----
# Hosts file only works for the system resolver. Apps using DoH/DoT bypass
# /etc/hosts entirely. The DNS enforcer forces Private DNS off and blocks
# well-known DoH/DoT endpoints so /etc/hosts is actually consulted.

DNS_PIDFILE="$STATE_DIR/dns_enforcer.pid"






# ---- Launcher enforcer ----

LAUNCHER_PIDFILE="$STATE_DIR/launcher_enforcer.pid"
DISABLED_COMPETITORS_FILE="$STATE_DIR/disabled_competitors.txt"







# ---- Workout detector ----

WORKOUT_PIDFILE="$STATE_DIR/workout_detector.pid"






# ============================================================
# Night-curfew control (see curfew_enforcer.sh / focus_daemon.sh)
# ============================================================
CURFEW_PIDFILE="$STATE_DIR/curfew_enforcer.pid"






cmd_curfew_log() { tail -n "${1:-50}" "$CURFEW_ENFORCER_LOG" 2>/dev/null || echo "No curfew log yet."; }







# ============================================================
# Hotspot / tethering block control (see tether_enforcer.sh)
# ============================================================
TETHER_PIDFILE="$STATE_DIR/tether_enforcer.pid"








case "$1" in
start) cmd_start ;;
stop) cmd_stop ;;
status) cmd_status ;;
enable) cmd_enable ;;
disable) cmd_disable ;;
log) cmd_log "${2:-50}" ;;
list-apps) cmd_list_apps ;;
whitelist) cmd_whitelist ;;
restart)
	cmd_stop
	sleep 2
	cmd_start
	;;
hosts-status) cmd_hosts_status ;;
hosts-start) cmd_hosts_start ;;
hosts-stop) cmd_hosts_stop ;;
hosts-log) cmd_hosts_log "${2:-50}" ;;
dns-status) cmd_dns_status ;;
dns-start) cmd_dns_start ;;
dns-stop) cmd_dns_stop ;;
dns-log) cmd_dns_log "${2:-50}" ;;
launcher-status) cmd_launcher_status ;;
launcher-start) cmd_launcher_start ;;
launcher-stop) cmd_launcher_stop ;;
launcher-log) cmd_launcher_log "${2:-50}" ;;
launcher-snapshot) cmd_launcher_snapshot ;;
workout-status) cmd_workout_status ;;
workout-start) cmd_workout_start ;;
workout-stop) cmd_workout_stop ;;
workout-log) cmd_workout_log "${2:-50}" ;;
recheck) cmd_recheck ;;
notif-status) cmd_notif_status ;;
curfew-status) cmd_curfew_status ;;
curfew-start) cmd_curfew_start ;;
curfew-stop) cmd_curfew_stop ;;
curfew-log) cmd_curfew_log "${2:-50}" ;;
curfew-test-on) cmd_curfew_test_on ;;
curfew-test-off) cmd_curfew_test_off ;;
curfew-demo-on) cmd_curfew_demo_on ;;
curfew-demo-off) cmd_curfew_demo_off ;;
curfew-off) cmd_curfew_off ;;
curfew-on) cmd_curfew_on ;;
tether-status) cmd_tether_status ;;
tether-start) cmd_tether_start ;;
tether-stop) cmd_tether_stop ;;
tether-log) cmd_tether_log "${2:-50}" ;;
tether-test-on) cmd_tether_test_on ;;
tether-test-off) cmd_tether_test_off ;;
*) usage ;;
esac
