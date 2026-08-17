#!/bin/bash
# deploy_gps.sh — the home-coordinate capture: reading a fix off the phone
# when config_secrets.sh still holds placeholders, and the --capture-coords
# action that writes one deliberately.
#
# Sourced by deploy.sh, which owns adb_cmd and $DEPLOY_DIR. $NEEDS_GPS_FETCH
# is written by check_coords here and read by the deploy run, so it stays
# declared in deploy.sh with the other run-scoped state.

check_coords() {
	local lat lon
	lat="$(grep '^.*HOME_LAT=' "$DEPLOY_DIR/config.sh" "$DEPLOY_DIR/config_secrets.sh" 2>/dev/null | tail -1 | cut -d'"' -f2)"
	lon="$(grep '^.*HOME_LON=' "$DEPLOY_DIR/config.sh" "$DEPLOY_DIR/config_secrets.sh" 2>/dev/null | tail -1 | cut -d'"' -f2)"
	if [ "$lat" = "0.000000" ] && [ "$lon" = "0.000000" ]; then
		echo "ERROR: Home coordinates not set (all zeros)."
		exit 1
	fi
	# If both look like valid floats, use them; otherwise auto-capture from
	# phone GPS. The answer is the EXIT STATUS rather than an assignment to
	# $NEEDS_GPS_FETCH: this file would otherwise write a global it never
	# reads (SC2034), and the linter runs without -x so each file has to
	# stand alone. deploy.sh sets the flag from what this returns.
	if [[ -n "$lat" && "$lat" =~ ^[+-]?[0-9]+\.[0-9]+$ && -n "$lon" && "$lon" =~ ^[+-]?[0-9]+\.[0-9]+$ ]]; then
		echo "  Home location: $lat, $lon"
		return 1
	fi
	echo "  Home location: placeholder — will be captured from phone GPS at deploy time."
	return 0
}

fetch_home_coords_from_phone() {
	echo "  Enabling location services on phone..." >&2
	adb_cmd shell settings put secure location_mode 3 2>/dev/null || true

	echo "  Waiting for network/fused location fix (up to ${GPS_MAX_WAIT_SECS}s)..." >&2
	local waited=0 coords=""
	while [[ -z "$coords" && $waited -lt $GPS_MAX_WAIT_SECS ]]; do
		sleep 3
		waited=$((waited + 3))
		# Format on Android 10+: "      last location=Location[fused LAT,LON ...]"
		local raw
		raw="$(adb_cmd shell dumpsys location 2>/dev/null |
			grep 'last location=Location\[' |
			grep -oE '[+-]?[0-9]+\.[0-9]+,[+-]?[0-9]+\.[0-9]+' |
			head -1 || true)"
		[[ -n "$raw" ]] && coords="$raw"
		printf '.' >&2
	done
	printf '\n' >&2

	if [[ -z "$coords" ]]; then
		echo "ERROR: No location fix after ${GPS_MAX_WAIT_SECS}s." >&2
		echo "  Make sure the phone has cellular or WiFi data, then retry." >&2
		echo "  Or set HOME_LAT/HOME_LON manually in config_secrets.sh." >&2
		return 1
	fi

	local lat="${coords%,*}"
	local lon="${coords#*,}"
	echo "  GPS fix acquired: ${lat}, ${lon}" >&2
	printf '%s %s' "$lat" "$lon"
}

do_capture_coords() {
	# Standalone GPS capture for post-WiFi-setup use.
	# Overwrites config_secrets.sh on the phone with the current location.
	connect_adb
	if ! adb_root "id" 2>/dev/null | grep -q "uid=0"; then
		echo "ERROR: Root not available."
		exit 1
	fi
	echo "Capturing home coordinates from phone GPS..."
	local gps_result gps_lat gps_lon
	gps_result="$(fetch_home_coords_from_phone)"
	gps_lat="${gps_result% *}"
	gps_lon="${gps_result#* }"
	adb_root "printf '#!/system/bin/sh\n# Home coordinates auto-captured from GPS\nexport HOME_LAT=\"${gps_lat}\"\nexport HOME_LON=\"${gps_lon}\"\n' \
        > $REMOTE_DIR/config_secrets.sh"
	echo "Home coordinates updated on phone: ${gps_lat}, ${gps_lon}"
	echo "Restarting focus daemon to apply new coordinates..."
	adb_root "sh $REMOTE_DIR/focus_ctl.sh restart" 2>/dev/null || true
	echo "Done."
}
