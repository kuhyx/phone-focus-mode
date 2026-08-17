#!/bin/bash
# deploy_actions.sh — deploy.sh's non-deploy actions: the help text, passing a
# control command through to focus_ctl.sh on the phone, pulling the log,
# searching installed packages, and snapshotting the launcher APK.
#
# Sourced by deploy.sh, which owns adb_cmd, adb_root and $REMOTE_DIR.

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
