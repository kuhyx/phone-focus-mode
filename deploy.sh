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

_DEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=deploy_actions.sh
. "${_DEPLOY_LIB_DIR}/deploy_actions.sh"
# shellcheck source=deploy_gps.sh
. "${_DEPLOY_LIB_DIR}/deploy_gps.sh"
# shellcheck source=deploy_magisk.sh
. "${_DEPLOY_LIB_DIR}/deploy_magisk.sh"
# shellcheck source=deploy_phases.sh
. "${_DEPLOY_LIB_DIR}/deploy_phases.sh"
# shellcheck source=deploy_install.sh
. "${_DEPLOY_LIB_DIR}/deploy_install.sh"
# shellcheck source=deploy_daemons.sh
. "${_DEPLOY_LIB_DIR}/deploy_daemons.sh"

PHONE_IP="${1:-}"
ACTION="${2:---deploy}"
REMOTE_DIR="/data/local/tmp/focus_mode"
# Deliberately NOT named SCRIPT_DIR: config.sh (sourced below, at top
# level) assigns SCRIPT_DIR itself and may repoint it at the on-device
# path /data/local/tmp/focus_mode. Every path here must stay anchored to
# the checkout deploy.sh runs from.
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
NEEDS_GPS_FETCH=0 # set to 1 by check_coords when local coords are placeholder

# Source shared config constants (BROWSER_PACKAGES, REMOTE_DIR, etc.)
# shellcheck source=config.sh
. "$DEPLOY_DIR/config.sh"

ADB_TARGET=()

# Support orchestrator-driven device targeting via ADB_SERIAL.
# When ADB_SERIAL is set, deploy.sh uses that target directly and preserves
# the existing PHONE_IP workflow when ADB_SERIAL is unset.
# The APK argument for --sideload. Read here rather than in the case branch
# because the whole argv shifts by one when the IP is omitted (ADB_SERIAL
# form), and the branch cannot tell which form it was invoked in.
SIDELOAD_APK="${3:-}"

if [[ -n "${ADB_SERIAL:-}" ]]; then
	ADB_TARGET=(-s "${ADB_SERIAL}")
	if [[ -z "${PHONE_IP}" || "${PHONE_IP}" == --* ]]; then
		ACTION="${PHONE_IP:---deploy}"
		PHONE_IP=""
		SIDELOAD_APK="${2:-}"
	fi
fi

adb_cmd() {
	adb "${ADB_TARGET[@]}" "$@"
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
# --mount-master was removed in Magisk v26+; plain su -c works and still
# runs in the correct mount namespace for our use cases.
adb_root() {
	local command_text="$1"

	printf '%s\n' "$command_text" | adb_cmd shell su -c "sh -s"
}


# ============================================================
# GPS HOME COORDINATE CAPTURE
# ============================================================
# Called when config_secrets.sh has placeholder/non-numeric coords.
# Enables Android location, waits up to GPS_MAX_WAIT_SECS for a
# network/fused fix, and prints "lat lon" on stdout.  All progress
# messages go to stderr so the caller can capture only the coords.
GPS_MAX_WAIT_SECS=90


# ============================================================
# MAGISK SYSTEMLESS HOSTS AUTO-INSTALL
# ============================================================
# Creates the module dir+module.prop if absent, removes disable
# markers if disabled, then reboots the device and waits up to
# HOSTS_MODULE_REBOOT_WAIT_SECS for it to come back with the
# magic-mount active.  No-ops if the module is already OK.
HOSTS_MODULE_REBOOT_WAIT_SECS=180


# ============================================================
# APP INSTALLS -- no store on the device
# ============================================================
# There is deliberately no app store here, not even a Play-free one.
#
# Aurora Store used to be installed by `--install-aurora`, on the reasoning
# that it let apps be installed while Play itself was blocked. Removed
# 2026-08-24: Aurora is a Play *client*. It can fetch any browser in the
# store, which is the exact bypass blocking Play exists to prevent, so it
# reproduced the hole one layer down while looking like a mitigation.
#
# Installing and updating apps is now a PC-side operation over adb, which
# keeps the install decision on this side of the airlock:
#
#   ./deploy.sh <ip> --sideload /path/to/app.apk
#
# See docs/DOCS-policy-lists.md#installing-and-updating-apps-without-a-store
# for the infakt update procedure, which is the case this has to serve.


# ============================================================
# DEPLOY
# ============================================================
do_deploy() {
	echo "=== Focus Mode Deployer ==="
	echo ""
	if check_coords; then
		NEEDS_GPS_FETCH=1
	else
		NEEDS_GPS_FETCH=0
	fi
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

	_deploy_push_scripts
}













# ============================================================
# Entry point
# ============================================================
check_adb
check_ip

case "$ACTION" in
--deploy | "") do_deploy ;;
--status) do_control "status" ;;
--log)
	connect_adb
	adb_root "sh $REMOTE_DIR/focus_ctl.sh log 100"
	;;
--stop) do_control "stop" ;;
--start) do_control "start" ;;
--restart) do_control "restart" ;;
--enable) do_control "enable" ;;
--disable) do_control "disable" ;;
--list) do_control "list-apps" ;;
--pull-log) do_pull_log ;;
--find-pkg) do_find_pkg "$@" ;;
--hosts-status) do_control "hosts-status" ;;
--hosts-log)
	connect_adb
	adb_root "sh $REMOTE_DIR/focus_ctl.sh hosts-log 100"
	;;
--launcher-status) do_control "launcher-status" ;;
--launcher-log)
	connect_adb
	adb_root "sh $REMOTE_DIR/focus_ctl.sh launcher-log 100"
	;;
--capture-coords) do_capture_coords ;;
--snapshot-launcher) do_snapshot_launcher ;;
--sideload) do_sideload "$SIDELOAD_APK" ;;
*)
	echo "Unknown action: $ACTION"
	usage
	;;
esac
