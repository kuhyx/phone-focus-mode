#!/bin/bash
# deploy_magisk.sh — the Magisk systemless-hosts module: creating it when
# absent, clearing its disable markers, and rebooting to bring the magic mount
# up. Also carries the APK sideload helper and the file-hash helper, both
# of which are one-off setup rather than part of a deploy run.
#
# Sourced by deploy.sh, which owns adb_cmd and adb_root.

compute_file_hash() {
	local path="$1"

	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{print $1}'
		return 0
	fi

	md5sum "$path" | awk '{print $1}'
}

ensure_magisk_hosts_module() {
	local state="absent"
	if adb_root "test -d /data/adb/modules/hosts" >/dev/null 2>&1; then
		if adb_root "test -f /data/adb/modules/hosts/disable -o -f /data/adb/modules/hosts/remove" >/dev/null 2>&1; then
			state="disabled"
		elif adb_root "test -f /system/etc/hosts" >/dev/null 2>&1; then
			state="ok"
		else
			state="not-mounted"
		fi
	fi

	if [[ "$state" == "ok" ]]; then
		echo "  Magisk Systemless Hosts: active."
		return 0
	fi

	echo "  Magisk Systemless Hosts state: ${state} — auto-installing..."

	case "$state" in
	absent)
		adb_root "mkdir -p /data/adb/modules/hosts/system/etc"
		# module.prop is required for Magisk to recognise and process the module.
		adb_root "printf 'id=hosts\nname=Systemless Hosts\nversion=v1\nversionCode=1\nauthor=Magisk\ndescription=Replace /system/etc/hosts\n' \
                > /data/adb/modules/hosts/module.prop"
		# Seed a minimal hosts file so the mount target exists at first boot.
		adb_root "printf '127.0.0.1 localhost\n::1 localhost\n' \
                > /data/adb/modules/hosts/system/etc/hosts"
		adb_root "chmod 644 /data/adb/modules/hosts/system/etc/hosts"
		;;
	disabled)
		adb_root "rm -f /data/adb/modules/hosts/disable \
                           /data/adb/modules/hosts/remove \
                           /data/adb/modules/hosts/update"
		;;
	not-mounted)
		: # module exists and enabled, just needs a reboot
		;;
	esac

	echo "  Rebooting phone to activate Magisk Hosts module..."
	adb_cmd reboot
	# Give the device time to actually begin shutting down before we poll.
	sleep 20

	echo "  Waiting for device to come back (up to ${HOSTS_MODULE_REBOOT_WAIT_SECS}s)..."
	local waited=0
	# Re-establish wireless ADB connection if needed.
	while true; do
		if [[ -n "${PHONE_IP:-}" ]]; then
			adb connect "${PHONE_IP}:5555" >/dev/null 2>&1 || true
		fi
		if adb_cmd shell echo ok 2>/dev/null | grep -q '^ok$'; then
			break
		fi
		sleep 3
		waited=$((waited + 3))
		if [[ $waited -ge $HOSTS_MODULE_REBOOT_WAIT_SECS ]]; then
			echo "ERROR: Device did not come back after ${HOSTS_MODULE_REBOOT_WAIT_SECS}s."
			echo "  Check USB connection or re-enable wireless ADB, then run deploy again."
			exit 1
		fi
		printf '.'
	done
	printf '\n'

	# Wait for Magisk early-init and root to be ready.
	echo "  Waiting for Magisk root to be available..."
	waited=0
	while ! adb_root "id" 2>/dev/null | grep -q "uid=0"; do
		sleep 3
		waited=$((waited + 3))
		[[ $waited -ge 60 ]] && echo "ERROR: Root not available after reboot." && exit 1
		printf '.'
	done
	printf '\n'

	# Final assertion: the magic-mount must now be active.
	if ! adb_root "test -f /system/etc/hosts" >/dev/null 2>&1; then
		echo "ERROR: /system/etc/hosts is not magic-mounted after reboot."
		echo "  Magisk may not have applied the module correctly."
		echo "  Check the Magisk app for module errors and run deploy again."
		exit 1
	fi
	echo "  Magisk Systemless Hosts module is now active."
}

do_sideload() {
	local apk="$1"

	if [ -z "$apk" ]; then
		echo "ERROR: --sideload needs an APK path."
		echo "Usage: $0 <ip> --sideload /path/to/app.apk"
		return 1
	fi
	if [ ! -f "$apk" ]; then
		echo "ERROR: no such APK: $apk"
		return 1
	fi

	connect_adb

	# install -r, never uninstall-then-install: a reinstall would drop app
	# data, and for the app this exists to serve (infakt) that means losing
	# the device pairing this whole procedure is trying to preserve.
	echo "Sideloading $(basename "$apk")..."
	if adb_cmd install -r "$apk"; then
		echo "Installed. No store was involved, which is the point:"
		echo "see docs/DOCS-policy-lists.md#installing-and-updating-apps-without-a-store"
	else
		echo "ERROR: adb install failed for $apk"
		return 1
	fi
}
