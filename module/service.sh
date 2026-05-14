#!/system/bin/sh
# Android Guardian Service - runs at boot
# This service:
# 1. Monitors and protects the hosts file
# 2. Blocks installation of forbidden apps
# 3. Prevents module from being disabled via Magisk UI
# 4. Can only be stopped via ADB with the correct command

MODDIR=${0%/*}
GUARDIAN_DIR="${ANDROID_GUARDIAN_DIR:-/data/adb/android_guardian}"
LOG_FILE="$GUARDIAN_DIR/guardian.log"
BLOCKED_APPS_FILE="$GUARDIAN_DIR/blocked_apps.txt"
CONTROL_FILE="$GUARDIAN_DIR/control"
HOSTS_BACKUP="$GUARDIAN_DIR/hosts.backup"
MODULE_DIR="${ANDROID_GUARDIAN_MODULE_DIR:-/data/adb/modules/android_guardian}"
SYSTEM_HOSTS_FILE="${ANDROID_GUARDIAN_SYSTEM_HOSTS_FILE:-/system/etc/hosts}"
MODULE_HOSTS_FILE="${ANDROID_GUARDIAN_MODULE_HOSTS_FILE:-$MODDIR/system/etc/hosts}"
DISABLE_FILE="$MODULE_DIR/disable"
REMOVE_FILE="$MODULE_DIR/remove"
LOOP_SLEEP_SECONDS=5
HOSTS_CHECK_EVERY_TICKS=6
APPS_CHECK_EVERY_TICKS=12

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_FILE"
}

initialize_service() {
	mkdir -p "$GUARDIAN_DIR"

	if [ ! -f "$CONTROL_FILE" ]; then
		echo "ENABLED" >"$CONTROL_FILE"
	fi

	log "=== Android Guardian starting ==="

	# Enable wireless ADB on boot (persistent port 5555)
	setprop service.adb.tcp.port 5555
	stop adbd
	start adbd
	log "Wireless ADB enabled on port 5555"
}

# Function to check if guardian is enabled (via ADB control, not Magisk UI)
is_enabled() {
	[ "$(cat "$CONTROL_FILE" 2>/dev/null)" = "ENABLED" ]
}

# Function to protect module from being disabled via Magisk UI
protect_module() {
	# Remove disable file if someone tried to disable via Magisk
	if [ -f "$DISABLE_FILE" ]; then
		log "Module disable attempt detected via Magisk UI! Re-enabling..."
		rm -f "$DISABLE_FILE"
		log "Module re-enabled"
	fi

	# Remove remove file if someone tried to uninstall via Magisk
	if [ -f "$REMOVE_FILE" ]; then
		log "Module removal attempt detected via Magisk UI! Blocking..."
		rm -f "$REMOVE_FILE"
		log "Module removal blocked"
	fi
}

# Function to restore hosts file if tampered
protect_hosts() {
	if [ -f "$HOSTS_BACKUP" ]; then
		if ! cmp -s "$SYSTEM_HOSTS_FILE" "$HOSTS_BACKUP"; then
			log "Hosts file tampering detected! Restoring..."
			cp "$HOSTS_BACKUP" "$MODULE_HOSTS_FILE"
			log "Hosts file restored"
		fi
	fi
}

# Function to uninstall blocked apps
check_blocked_apps() {
	if [ ! -f "$BLOCKED_APPS_FILE" ]; then
		return
	fi

	installed_packages=$(pm list packages 2>/dev/null) || installed_packages=""
	if [ -z "$installed_packages" ]; then
		return
	fi
	installed_packages="
$installed_packages
"

	while IFS= read -r package || [ -n "$package" ]; do
		# Skip comments and empty lines
		case "$package" in
		\#* | "") continue ;;
		esac

		# Check if package is installed
		case "$installed_packages" in
		*"
package:$package
"*)
			log "Blocked app detected: $package - Uninstalling..."
			pm uninstall "$package" 2>/dev/null && log "Uninstalled: $package" || log "Failed to uninstall: $package"
			;;
		esac
	done <"$BLOCKED_APPS_FILE"
}

guardian_loop() {
	tick_count=0
	while true; do
		# ALWAYS protect module from UI disabling (even if guardian is "disabled" via ADB)
		# This ensures only ADB can control the guardian
		protect_module

		if is_enabled; then
			if [ $((tick_count % HOSTS_CHECK_EVERY_TICKS)) -eq 0 ]; then
				protect_hosts
			fi

			if [ $((tick_count % APPS_CHECK_EVERY_TICKS)) -eq 0 ]; then
				check_blocked_apps
			fi
		fi

		tick_count=$((tick_count + 1))
		sleep "$LOOP_SLEEP_SECONDS"
	done
}

service_main() {
	initialize_service
	guardian_loop &
	log "Guardian service started (PID: $!)"
}

if [ "${ANDROID_GUARDIAN_SKIP_MAIN:-0}" -ne 1 ]; then
	service_main
fi
