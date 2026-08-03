#!/bin/bash

# ============================================================================
# Make adb-over-Wi-Fi permanent on the phone (port 5555).
#
# Android's "Wireless debugging" is deliberately ephemeral: the listener dies
# when you leave the settings screen or the device sleeps, and it picks a new
# random port every time it comes back. That is why every deploy so far has
# needed someone to tap through the phone first.
#
# This script waits for ANY transient wireless-debugging window, then uses it
# to switch adbd to a fixed port 5555 and installs a Magisk boot script so the
# same thing happens on every boot. After one successful run the phone is
# reachable at $PHONE_IP:5555 forever, with no tapping.
#
# Requires: root (Magisk) on the device, and the host already paired.
#
# Usage:
#   ./enable_persistent_adb.sh [PHONE_IP] [KNOWN_PORT]
#   PHONE_IP defaults to 192.168.1.64.
#   KNOWN_PORT, if given, is tried first before falling back to a port scan.
# ============================================================================

set -uo pipefail

PHONE_IP="${1:-192.168.1.64}"
readonly KNOWN_PORT="${2:-}"
readonly FIXED_PORT=5555
# The phone is on DHCP, so its address can move. Its MAC cannot, so that is
# what we actually identify it by; PHONE_IP is only a first guess.
readonly PHONE_MAC="00:08:22:68:81:fc"
# Android allocates the wireless-debugging port from the ephemeral range.
readonly SCAN_RANGE="30000-65535"
# Give up rather than spin forever if nobody ever wakes the phone.
readonly DEADLINE_SECONDS=1800

readonly BOOT_SCRIPT=/data/adb/service.d/99-adb-tcp-5555.sh

log() { printf '[persistent-adb] %s\n' "$1"; }

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: $1 is required but not installed" >&2
		exit 1
	fi
}

# Echo the serial iff THIS endpoint is connected and not offline.
#
# Deliberately matches the exact ip:port rather than the first `device` line.
# After pairing, adb also auto-connects an mDNS `_adb-tls-connect._tcp` entry
# for the same phone; taking the first line made `try_connect 5555` report
# success while port 5555 was in fact closed.
connected_serial() {
	local endpoint="$1"
	adb devices 2>/dev/null |
		awk -v want="$endpoint" '$1 == want && $2 == "device" {print $1; exit}'
}

# Try to reach adbd. Returns 0 and sets REPLY to the serial when connected.
try_connect() {
	local port="$1" endpoint
	endpoint="${PHONE_IP}:${port}"
	adb connect "$endpoint" >/dev/null 2>&1 || return 1
	# `connect` succeeds optimistically; the device can still be offline.
	sleep 2
	REPLY="$(connected_serial "$endpoint")"
	[[ -n "$REPLY" ]]
}

# Locate the phone on the current subnet by MAC and echo its IP.
#
# DHCP can hand the phone a different address at any time, which would break a
# hardcoded PHONE_IP. A ping sweep populates the neighbour table, then we look
# the MAC up in it. Prefer this over a router DHCP reservation because it needs
# no router access and keeps working on any network the laptop joins.
discover_ip_by_mac() {
	local subnet
	subnet="$(ip -4 route show dev "$(ip -4 route show default |
		awk '/default/ {print $5; exit}')" 2>/dev/null |
		awk '/proto kernel/ {print $1; exit}')"
	[[ -n "$subnet" ]] || return 1

	nmap -sn -T4 "$subnet" >/dev/null 2>&1
	ip neigh show 2>/dev/null |
		awk -v mac="$PHONE_MAC" 'tolower($5) == tolower(mac) {print $1; exit}'
}

# Find the current ephemeral wireless-debugging port, if one is listening.
scan_for_port() {
	nmap -p "$SCAN_RANGE" --open -T4 -Pn --min-rate 3000 "$PHONE_IP" 2>/dev/null |
		awk -F/ '/^[0-9]+\/tcp[[:space:]]+open/ {print $1}' | head -1
}

# Switch adbd to the fixed port and persist it across reboots.
make_permanent() {
	local serial="$1"

	if ! adb -s "$serial" shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
		echo "Error: no root on the device; cannot install the boot script." >&2
		echo "       adb tcpip $FIXED_PORT alone would not survive a reboot." >&2
		return 1
	fi

	log "installing Magisk boot script at $BOOT_SCRIPT"
	# service.d runs late in boot, after the network is up, which is what adbd
	# needs. Restarting adbd is what actually makes it re-read the port.
	adb -s "$serial" shell "su -c 'cat > $BOOT_SCRIPT'" <<EOF
#!/system/bin/sh
# Installed by phone_focus_mode/enable_persistent_adb.sh.
# Pin adb-over-Wi-Fi to a fixed port so the laptop can always connect without
# anyone tapping through Settings -> Wireless debugging first.
setprop service.adb.tcp.port $FIXED_PORT
stop adbd
start adbd
EOF
	adb -s "$serial" shell "su -c 'chmod 755 $BOOT_SCRIPT'"

	log "switching adbd to port $FIXED_PORT now"
	adb -s "$serial" shell "su -c 'setprop service.adb.tcp.port $FIXED_PORT; stop adbd; start adbd'"
	# adbd restarting drops every current connection, including this one.
	sleep 4
}

main() {
	require adb
	require nmap

	log "waiting for a wireless-debugging window on $PHONE_IP (up to $((DEADLINE_SECONDS / 60))m)"
	log "wake the phone and open Settings -> Developer options -> Wireless debugging"

	local deadline=$((SECONDS + DEADLINE_SECONDS))
	local serial=""

	while ((SECONDS < deadline)); do
		# Cheapest first: the fixed port may already be live from a prior run.
		if try_connect "$FIXED_PORT"; then
			serial="$REPLY"
			log "already reachable on $FIXED_PORT - nothing to do"
			printf '%s\n' "$serial"
			return 0
		fi

		# Not at the expected address — DHCP may have moved it. Re-find the
		# phone by MAC before concluding that adbd is down.
		local moved
		moved="$(discover_ip_by_mac)"
		if [[ -n "$moved" && "$moved" != "$PHONE_IP" ]]; then
			log "phone moved: $PHONE_IP -> $moved"
			PHONE_IP="$moved"
			if try_connect "$FIXED_PORT"; then
				serial="$REPLY"
				log "reachable on $FIXED_PORT at the new address"
				printf '%s\n' "$serial"
				return 0
			fi
		fi

		if [[ -n "$KNOWN_PORT" ]] && try_connect "$KNOWN_PORT"; then
			serial="$REPLY"
			break
		fi

		local found
		found="$(scan_for_port)"
		if [[ -n "$found" ]] && try_connect "$found"; then
			serial="$REPLY"
			break
		fi

		sleep 5
	done

	if [[ -z "$serial" ]]; then
		echo "Error: no wireless-debugging window appeared before the deadline." >&2
		return 1
	fi

	log "connected as $serial"
	make_permanent "$serial" || return 1

	if try_connect "$FIXED_PORT"; then
		log "SUCCESS: phone is now reachable at ${PHONE_IP}:${FIXED_PORT}"
		log "it will come back on this port after every reboot"
		printf '%s\n' "${PHONE_IP}:${FIXED_PORT}"
		return 0
	fi

	echo "Error: adbd did not come back on $FIXED_PORT after the switch." >&2
	return 1
}

main "$@"
