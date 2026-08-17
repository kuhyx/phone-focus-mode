#!/bin/bash
# deploy_phases.sh — the staging half of deploy.sh's deploy run: pushing every
# script to the device's staging directory, and preparing the generated assets
# (the sqlite3 binary and the canonical hosts files).
#
# Sourced by deploy.sh, which owns adb_cmd, adb_root and $DEPLOY_DIR.
#
# _deploy_push_scripts holds the FIRST of the two hardcoded file lists. The
# second is in deploy_install.sh. A new phone-side sibling has to be added to
# BOTH, or it is staged and never lands in $REMOTE_DIR -- and the script that
# sources it then fails to start with no obvious cause.

# Phase 4: stage every script and asset on the device. BOTH hardcoded
# lists live here -- the push list below and the cp list in
# _deploy_install_files -- and a new sibling must be added to each.
_deploy_push_scripts() {
	echo "[4/7] Uploading scripts..."
	adb_cmd push "$DEPLOY_DIR/config.sh" "/data/local/tmp/focus_stage/config.sh"
	adb_cmd push "$DEPLOY_DIR/config_paths.sh" "/data/local/tmp/focus_stage/config_paths.sh"
	adb_cmd push "$DEPLOY_DIR/config_dns.sh" "/data/local/tmp/focus_stage/config_dns.sh"
	adb_cmd push "$DEPLOY_DIR/config_curfew.sh" "/data/local/tmp/focus_stage/config_curfew.sh"
	adb_cmd push "$DEPLOY_DIR/config_tether.sh" "/data/local/tmp/focus_stage/config_tether.sh"
	adb_cmd push "$DEPLOY_DIR/config_launcher.sh" "/data/local/tmp/focus_stage/config_launcher.sh"
	adb_cmd push "$DEPLOY_DIR/focus_daemon.sh" "/data/local/tmp/focus_stage/focus_daemon.sh"
	adb_cmd push "$DEPLOY_DIR/daemon_location.sh" "/data/local/tmp/focus_stage/daemon_location.sh"
	adb_cmd push "$DEPLOY_DIR/daemon_state.sh" "/data/local/tmp/focus_stage/daemon_state.sh"
	adb_cmd push "$DEPLOY_DIR/daemon_apps.sh" "/data/local/tmp/focus_stage/daemon_apps.sh"
	adb_cmd push "$DEPLOY_DIR/focus_ctl.sh" "/data/local/tmp/focus_stage/focus_ctl.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_usage.sh" "/data/local/tmp/focus_stage/ctl_usage.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_daemon.sh" "/data/local/tmp/focus_stage/ctl_daemon.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_hosts.sh" "/data/local/tmp/focus_stage/ctl_hosts.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_dns.sh" "/data/local/tmp/focus_stage/ctl_dns.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_launcher.sh" "/data/local/tmp/focus_stage/ctl_launcher.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_workout.sh" "/data/local/tmp/focus_stage/ctl_workout.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_curfew.sh" "/data/local/tmp/focus_stage/ctl_curfew.sh"
	adb_cmd push "$DEPLOY_DIR/ctl_tether.sh" "/data/local/tmp/focus_stage/ctl_tether.sh"
	adb_cmd push "$DEPLOY_DIR/hosts_enforcer.sh" "/data/local/tmp/focus_stage/hosts_enforcer.sh"
	adb_cmd push "$DEPLOY_DIR/hosts_magisk.sh" "/data/local/tmp/focus_stage/hosts_magisk.sh"
	adb_cmd push "$DEPLOY_DIR/hosts_mount.sh" "/data/local/tmp/focus_stage/hosts_mount.sh"
	adb_cmd push "$DEPLOY_DIR/dns_enforcer.sh" "/data/local/tmp/focus_stage/dns_enforcer.sh"
	adb_cmd push "$DEPLOY_DIR/dns_iptables.sh" "/data/local/tmp/focus_stage/dns_iptables.sh"
	adb_cmd push "$DEPLOY_DIR/launcher_enforcer.sh" "/data/local/tmp/focus_stage/launcher_enforcer.sh"
	adb_cmd push "$DEPLOY_DIR/curfew_enforcer.sh" "/data/local/tmp/focus_stage/curfew_enforcer.sh"
	adb_cmd push "$DEPLOY_DIR/curfew_net.sh" "/data/local/tmp/focus_stage/curfew_net.sh"
	adb_cmd push "$DEPLOY_DIR/tether_enforcer.sh" "/data/local/tmp/focus_stage/tether_enforcer.sh"
	adb_cmd push "$DEPLOY_DIR/tether_iptables.sh" "/data/local/tmp/focus_stage/tether_iptables.sh"
	adb_cmd push "$DEPLOY_DIR/workout_detector.sh" "/data/local/tmp/focus_stage/workout_detector.sh"
	adb_cmd push "$DEPLOY_DIR/magisk_service.sh" "/data/local/tmp/focus_stage/99-focus-mode.sh"

	# ---- sqlite3 binary for workout_detector.sh ----
	# Stored outside the repo (binary-files policy). Built once via the NDK
	# against the SQLite amalgamation; see workout_detector.sh comments for
	# the recipe. ~1.6 MB stripped, aarch64, PIE, dynamically linked against
	# bionic (Android 30+).
	_deploy_stage_assets
}

# Stage the generated/vendored assets: the sqlite3 binary the workout
# detector needs, and the canonical hosts files built from the shared
# blocklist generator.
_deploy_stage_assets() {
	SQLITE3_BIN="$DEPLOY_DIR/../../testsAndMisc_binaries/phone_focus_mode/sqlite3"
	if [ -f "$SQLITE3_BIN" ]; then
		echo "  Uploading sqlite3 binary ($(stat -c%s "$SQLITE3_BIN") bytes)..."
		adb_cmd push "$SQLITE3_BIN" "/data/local/tmp/focus_stage/sqlite3"
	else
		echo "  WARNING: sqlite3 binary not found at $SQLITE3_BIN"
		echo "           workout_detector will not function until you build & place it there."
	fi

	# Generate and upload the canonical hosts file (StevenBlack + custom entries).
	# This mirrors what linux_configuration/hosts/install.sh installs on the PC.
	HOSTS_GENERATOR="$DEPLOY_DIR/../linux_configuration/scripts/periodic_background/hosts/generate_hosts_file.sh"
	if [ -f "$HOSTS_GENERATOR" ]; then
		chmod +x "$HOSTS_GENERATOR" 2>/dev/null || true
		echo "  Generating canonical hosts file..."
		HOSTS_TMP="$(mktemp)"
		HOSTS_SHA_TMP="$(mktemp)"
		if bash "$HOSTS_GENERATOR" "$HOSTS_TMP"; then
			hosts_hash="$(compute_file_hash "$HOSTS_TMP")"
			printf '%s\n' "$hosts_hash" >"$HOSTS_SHA_TMP"
			echo "  Uploading canonical hosts ($(wc -l <"$HOSTS_TMP") lines)..."
			adb_cmd push "$HOSTS_TMP" "/data/local/tmp/focus_stage/hosts.canonical"
			adb_cmd push "$HOSTS_SHA_TMP" "/data/local/tmp/focus_stage/hosts.sha256"

			# ---- Workout-variant canonical ----
			# Same content as the full canonical, with all lines that block
			# any of $WORKOUT_UNBLOCK_DOMAINS removed. Used by hosts_enforcer
			# while a StrongLifts workout is in progress.
			HOSTS_WORKOUT_TMP="$(mktemp)"
			HOSTS_WORKOUT_SHA_TMP="$(mktemp)"
			# Read $WORKOUT_UNBLOCK_DOMAINS from the freshly-staged config.sh
			# so the generator and the runtime always agree on the domain set.
			UNBLOCK_DOMAINS="$(
				# shellcheck disable=SC1091
				(
					. "$DEPLOY_DIR/config.sh" >/dev/null 2>&1
					printf '%s\n' "$WORKOUT_UNBLOCK_DOMAINS"
				) |
					sed 's/[[:space:]]\{1,\}/\n/g' |
					grep -vE '^[[:space:]]*(#|$)' |
					sort -u
			)"
			if [ -n "$UNBLOCK_DOMAINS" ]; then
				# Build an awk regex of exact-match domains anchored as the
				# *value* column of a hosts entry ("<ip> <domain>" possibly
				# followed by aliases). We strip any line whose first non-IP
				# token matches one of the unblock domains.
				WORKOUT_UNBLOCK_DOMAINS="$UNBLOCK_DOMAINS" \
					python3 "$DEPLOY_DIR/strip_workout_hosts.py" "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP" ||
					cp "$HOSTS_TMP" "$HOSTS_WORKOUT_TMP"
				workout_hash="$(compute_file_hash "$HOSTS_WORKOUT_TMP")"
				printf '%s\n' "$workout_hash" >"$HOSTS_WORKOUT_SHA_TMP"
				stripped_lines=$(($(wc -l <"$HOSTS_TMP") - $(wc -l <"$HOSTS_WORKOUT_TMP")))
				echo "  Uploading workout-variant hosts (stripped $stripped_lines YouTube lines)..."
				adb_cmd push "$HOSTS_WORKOUT_TMP" "/data/local/tmp/focus_stage/hosts.canonical.workout"
				adb_cmd push "$HOSTS_WORKOUT_SHA_TMP" "/data/local/tmp/focus_stage/hosts.sha256.workout"
			fi
			rm -f "$HOSTS_WORKOUT_TMP" "$HOSTS_WORKOUT_SHA_TMP"

			rm -f "$HOSTS_TMP"
			rm -f "$HOSTS_SHA_TMP"
		else
			rm -f "$HOSTS_TMP"
			rm -f "$HOSTS_SHA_TMP"
			echo "  WARNING: failed to generate hosts file - skipping hosts enforcement"
		fi
	else
		echo "  WARNING: $HOSTS_GENERATOR not found - skipping hosts enforcement"
	fi

	# Only push config_secrets.sh if phone doesn't already have one
	if adb_root "test -f $REMOTE_DIR/config_secrets.sh" 2>/dev/null; then
		echo "  config_secrets.sh already exists on phone - skipping (preserving real coords)"
	elif [[ "${NEEDS_GPS_FETCH}" -eq 1 ]]; then
		# Local config_secrets.sh has placeholder coords — capture current GPS from the phone.
		# The phone is assumed to be at home during setup, so current location = home location.
		local gps_result="" gps_lat="" gps_lon=""
		if gps_result="$(fetch_home_coords_from_phone 2>&1)"; then
			gps_lat="${gps_result% *}"
			gps_lon="${gps_result#* }"
			adb_root "printf '#!/system/bin/sh\n# Home coordinates auto-captured from GPS at deploy time\nexport HOME_LAT=\"${gps_lat}\"\nexport HOME_LON=\"${gps_lon}\"\n' \
                > $REMOTE_DIR/config_secrets.sh"
			echo "  Home coordinates written to phone: ${gps_lat}, ${gps_lon}"
		else
			# GPS unavailable (no WiFi/cellular yet on fresh phone).
			# Write stub coords — focus mode stays OFF, hosts/DNS blocking still works.
			# User should run:  ./deploy.sh [ip] --capture-coords  after configuring WiFi.
			adb_root "printf '#!/system/bin/sh\n# STUB: run ./deploy.sh --capture-coords after WiFi setup\nexport HOME_LAT=\"0.000001\"\nexport HOME_LON=\"0.000001\"\n' \
                > $REMOTE_DIR/config_secrets.sh"
			echo "  WARNING: GPS capture failed — focus mode location enforcement is DISABLED."
			echo "  Hosts/DNS blocking is active.  After configuring WiFi, run:"
			echo "    ADB_SERIAL=${ADB_SERIAL:-\$PHONE_IP:5555} ./deploy.sh --capture-coords"
		fi
	else
		echo "  Pushing config_secrets.sh (first install)..."
		adb_cmd push "$DEPLOY_DIR/config_secrets.sh" "/data/local/tmp/focus_stage/config_secrets.sh"
		adb_root "cp /data/local/tmp/focus_stage/config_secrets.sh $REMOTE_DIR/config_secrets.sh"
	fi

	# Move staged files into place with root
	_deploy_install_files
}
