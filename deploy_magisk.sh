#!/bin/bash
# deploy_magisk.sh — the Magisk systemless-hosts module: creating it when
# absent, clearing its disable markers, and rebooting to bring the magic mount
# up. Also carries the Aurora Store installer and the file-hash helper, both
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

do_install_aurora() {
	connect_adb

	# Check if already installed.
	if adb_cmd shell pm list packages 2>/dev/null | grep -qx "package:${AURORA_PACKAGE}"; then
		echo "Aurora Store is already installed (${AURORA_PACKAGE})."
		return 0
	fi

	echo "Downloading Aurora Store ${AURORA_VERSION}..."
	local tmp_apk
	tmp_apk="$(mktemp --suffix=.apk)"
	if ! curl -fsSL --retry 3 -o "$tmp_apk" "$AURORA_APK_URL"; then
		rm -f "$tmp_apk"
		echo "ERROR: Failed to download Aurora Store from $AURORA_APK_URL"
		echo "Manual download: https://auroraoss.com/"
		return 1
	fi

	echo "Installing Aurora Store..."
	if adb_cmd install -r "$tmp_apk"; then
		echo "Aurora Store ${AURORA_VERSION} installed successfully."
		echo "Open Aurora Store on the phone, choose 'Anonymous' login, then install apps normally."
	else
		echo "ERROR: adb install failed. You can side-load manually:"
		echo "  adb install ${tmp_apk}"
	fi
	rm -f "$tmp_apk"
}
