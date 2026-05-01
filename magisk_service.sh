#!/bin/sh
# ============================================================
# Magisk service.d autostart script
# This file is placed on the device at:
#   /data/adb/service.d/99-focus-mode.sh
# Magisk executes everything in service.d on boot with root.
# ============================================================

set -eu

SCRIPT_DIR="${FOCUS_MODE_SCRIPT_DIR:-/data/local/tmp/focus_mode}"

load_launcher_config() {
	if [ -f "$SCRIPT_DIR/config.sh" ]; then
		export FOCUS_MODE_SCRIPT_DIR="$SCRIPT_DIR"
		# shellcheck source=/dev/null
		. "$SCRIPT_DIR/config.sh"
		return 0
	fi

	return 1
}

boot_config_ready() {
	[ -f "$SCRIPT_DIR/config.sh" ]
}

launcher_boot_autostart_enabled() {
	load_launcher_config || return 1
	[ "${LAUNCHER_BOOT_AUTOSTART:-0}" = "1" ]
}

launcher_boot_snapshot_ready() {
	load_launcher_config || return 1
	[ -s "${LAUNCHER_APK:-}" ] && [ -s "${LAUNCHER_ACTIVITY_FILE:-}" ]
}

should_start_boot_stack() {
	load_launcher_config || return 1
	[ "${FOCUS_BOOT_AUTOSTART:-0}" = "1" ]
}

boot_delay_seconds() {
	load_launcher_config || {
		echo 10
		return 0
	}

	raw_delay="${FOCUS_BOOT_DELAY_SECONDS:-10}"
	case "$raw_delay" in
		''|*[!0-9]*)
			echo 10
			return 0
			;;
	esac

	# Safety cap requested by user: keep post-boot delay short.
	if [ "$raw_delay" -gt 10 ]; then
		echo 10
		return 0
	fi

	echo "$raw_delay"
}

boot_emergency_disable_file() {
	load_launcher_config || {
		echo "$SCRIPT_DIR/disable_boot_autostart"
		return 0
	}

	echo "${FOCUS_BOOT_EMERGENCY_DISABLE_FILE:-$SCRIPT_DIR/disable_boot_autostart}"
}

boot_emergency_disabled() {
	marker_file="$(boot_emergency_disable_file)"
	[ -f "$marker_file" ]
}

wait_for_boot_completed() {
	elapsed=0
	max_wait="${FOCUS_BOOT_WAIT_MAX_SECONDS:-180}"

	while [ "$elapsed" -lt "$max_wait" ]; do
		if [ "$(getprop sys.boot_completed 2>/dev/null || true)" = "1" ]; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	return 1
}

wait_for_boot_config() {
	elapsed=0
	max_wait="${FOCUS_BOOT_WAIT_MAX_SECONDS:-180}"

	while [ "$elapsed" -lt "$max_wait" ]; do
		if boot_config_ready; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	return 1
}

should_start_launcher_enforcer() {
	launcher_boot_autostart_enabled && launcher_boot_snapshot_ready
}

safe_chmod() {
	if [ -f "$1" ]; then
		chmod +x "$1"
	fi
}

start_launcher_enforcer_if_safe() {
	if should_start_launcher_enforcer; then
		setsid sh "$SCRIPT_DIR/launcher_enforcer.sh" </dev/null >/dev/null 2>&1 &
		return 0
	fi

	return 1
}

main() {
	if ! wait_for_boot_config; then
		exit 0
	fi

	if ! should_start_boot_stack; then
		exit 0
	fi

	if boot_emergency_disabled; then
		exit 0
	fi

	if ! wait_for_boot_completed; then
		exit 0
	fi

	sleep "$(boot_delay_seconds)"

	if boot_emergency_disabled; then
		exit 0
	fi

	# Ensure scripts are executable.
	safe_chmod "$SCRIPT_DIR/focus_daemon.sh"
	safe_chmod "$SCRIPT_DIR/focus_ctl.sh"
	safe_chmod "$SCRIPT_DIR/hosts_enforcer.sh"
	safe_chmod "$SCRIPT_DIR/dns_enforcer.sh"
	safe_chmod "$SCRIPT_DIR/launcher_enforcer.sh"

	# Start hosts enforcer FIRST - it must bind-mount the hosts file before
	# the user has a chance to exploit it. This runs even outside focus mode
	# because hosts hardening should always be active.
	setsid sh "$SCRIPT_DIR/hosts_enforcer.sh" </dev/null >/dev/null 2>&1 &

	# Start DNS enforcer - forces Private DNS off and blocks DoH/DoT endpoints
	# so the hosts file actually gets consulted by apps that would otherwise
	# bypass it (e.g. Chrome's built-in secure DNS). Always on.
	setsid sh "$SCRIPT_DIR/dns_enforcer.sh" </dev/null >/dev/null 2>&1 &

	# Start launcher enforcer only when boot autostart is explicitly enabled
	# and a valid launcher snapshot exists. This avoids boot loops or a blank
	# HOME screen caused by stale launcher state after OTA updates/resets.
	start_launcher_enforcer_if_safe || true

	# Start focus daemon in a new session (detached from any controlling terminal).
	setsid sh "$SCRIPT_DIR/focus_daemon.sh" </dev/null >/dev/null 2>&1 &

	exit 0
}

if [ "${FOCUS_MODE_MAGISK_SERVICE_TESTING:-0}" != "1" ]; then
	main "$@"
fi
