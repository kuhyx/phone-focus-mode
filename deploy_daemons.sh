#!/bin/bash
# deploy_daemons.sh — the last phases of a deploy: restarting the enforcers,
# installing the companion status-notification app, and printing the closing
# summary.
#
# Sourced by deploy.sh, which owns adb_cmd, adb_root and $REMOTE_DIR.

# Phase 6: stop anything already running, then start each enforcer.
_deploy_start_daemons() {
	echo "[6/7] Starting daemons..."
	# Stop existing daemons, then start fresh
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/focus_daemon.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/hosts_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/dns_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/launcher_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/curfew_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/tether_enforcer.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/workout_detector.sh' 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done"
	adb_root "kill \$(cat $REMOTE_DIR/daemon.pid 2>/dev/null)            2>/dev/null; true"
	adb_root "kill \$(cat $REMOTE_DIR/hosts_enforcer.pid 2>/dev/null)    2>/dev/null; true"
	adb_root "kill \$(cat $REMOTE_DIR/dns_enforcer.pid 2>/dev/null)      2>/dev/null; true"
	adb_root "kill \$(cat $REMOTE_DIR/launcher_enforcer.pid 2>/dev/null) 2>/dev/null; true"
	adb_root "kill \$(cat $REMOTE_DIR/tether_enforcer.pid 2>/dev/null)   2>/dev/null; true"
	adb_root "kill \$(cat $REMOTE_DIR/workout_detector.pid 2>/dev/null)  2>/dev/null; true"
	sleep 1
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/focus_daemon.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/hosts_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/dns_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/launcher_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/curfew_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/tether_enforcer.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	adb_root "for p in \$(pgrep -f '/data/local/tmp/focus_mode/workout_detector.sh' 2>/dev/null); do kill -9 \"\$p\" 2>/dev/null || true; done"
	sleep 1
	adb_root "rm -f $REMOTE_DIR/daemon.pid $REMOTE_DIR/hosts_enforcer.pid $REMOTE_DIR/dns_enforcer.pid $REMOTE_DIR/launcher_enforcer.pid $REMOTE_DIR/tether_enforcer.pid $REMOTE_DIR/workout_detector.pid"
	# Start hosts enforcer first so hosts are locked before user can react.
	# Use --mount-master so bind mounts propagate to the global namespace
	# (where app processes live). Without this, only our isolated `su` session
	# would see the bind-mounted hosts file.
	if adb_root "test -f $REMOTE_DIR/hosts.canonical" 2>/dev/null; then
		adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/hosts_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
	fi
	# Start workout detector BEFORE the hosts enforcer's first integrity check
	# so the enforcer sees a non-stale workout_active flag. The detector itself
	# is harmless if no workout is in progress (it just writes 0).
	if adb_root "test -x $REMOTE_DIR/sqlite3" 2>/dev/null; then
		adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/workout_detector.sh </dev/null >/dev/null 2>/dev/null &'
	fi
	# Start DNS enforcer (forces Private DNS off, blocks DoH/DoT). Always on.
	adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/dns_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
	# Start launcher enforcer only if a snapshot APK exists. If not, warn the
	# user to install Minimalist Phone + run --snapshot-launcher first.
	if adb_root "test -f $REMOTE_DIR/minimalist_launcher.apk" 2>/dev/null; then
		adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/launcher_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
	else
		echo "  NOTE: launcher snapshot missing. Install Minimalist Phone via Aurora Store, then run:"
		echo "        $0 $PHONE_IP --snapshot-launcher"
	fi
	# Start night-curfew enforcer (grayscale + DND + optional net allow-list).
	# Always on; self-gates on the clock + focus mode, no-op during the day.
	adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/curfew_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
	# Start hotspot/tethering enforcer (blocks forwarded/tethered traffic so a
	# second phone on our hotspot can't bypass focus mode). Always on; self-gates
	# on focus mode, no-op while away from home.
	adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/tether_enforcer.sh </dev/null >/dev/null 2>/dev/null &'
	adb_cmd shell su --mount-master -c 'setsid sh /data/local/tmp/focus_mode/focus_daemon.sh </dev/null >/dev/null 2>/dev/null &'

	# Wait for hosts_enforcer to apply the bind mount and restart netd.
	# hosts_enforcer.sh restarts netd once at startup (takes ~4 s); we wait
	# 10 s total so the network is stable before the companion-app install.
	sleep 10

	_deploy_install_companion
}

# Phase 7: build and install the companion status-notification app.
_deploy_install_companion() {
	# ---- Companion status notification app ----
	APP_DIR="$DEPLOY_DIR/focus_status_app"
	APK="$APP_DIR/build/focus_status.apk"
	if [ -d "$APP_DIR" ]; then
		echo "[7/7] Building & installing companion status-notification app..."
		needs_rebuild=0
		if [ ! -f "$APK" ]; then
			needs_rebuild=1
		elif [ "$APP_DIR/AndroidManifest.xml" -nt "$APK" ]; then
			needs_rebuild=1
		elif [ "$APP_DIR/build.sh" -nt "$APK" ]; then
			needs_rebuild=1
		elif find "$APP_DIR/java" -name '*.java' -newer "$APK" -print -quit 2>/dev/null | grep -q .; then
			# Rebuild when any Java source changed, not just the manifest.
			needs_rebuild=1
		fi
		if [ "$needs_rebuild" -eq 1 ]; then
			echo "  Building APK..."
			# Non-fatal: the companion UI is optional. If the Android SDK is
			# missing (build.sh fails), warn and fall back to the existing APK
			# rather than aborting the whole deploy and leaving the curfew core
			# un-started.
			if ! (cd "$APP_DIR" && bash build.sh) >/dev/null 2>&1; then
				echo "  WARNING: APK build failed (Android SDK missing?)."
				echo "           Keeping the previously-built APK if present;"
				echo "           the curfew daemons/enforcers are unaffected."
			fi
		fi
		if [ -f "$APK" ]; then
			echo "  Installing APK..."
			adb_cmd install -r "$APK" >/dev/null || true
			# Grant runtime permission (Android 13+ requires it for notifications).
			adb_cmd shell pm grant com.kuhy.focusstatus android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
			# Pre-approve Magisk SU so the app never shows the approval prompt.
			APP_UID="$(
				adb_cmd shell dumpsys package com.kuhy.focusstatus 2>/dev/null |
					awk 'match($0, /userId=[0-9]+/) {print substr($0, RSTART + 7, RLENGTH - 7); exit}'
			)"
			if [ -n "$APP_UID" ]; then
				adb_cmd shell "su -c 'magisk --sqlite \"INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($APP_UID,2,0,1,1)\"'" >/dev/null 2>&1 || true
			fi
			# Launch the invisible activity which kicks off the foreground service.
			adb_cmd shell am start -n com.kuhy.focusstatus/.LaunchActivity >/dev/null 2>&1 || true
			echo "  Companion app running (look for the ongoing 'Focus Mode' notification)."
		else
			echo "  WARNING: APK build failed - skipping companion app install"
		fi
	fi

	_deploy_report
}

# Print the closing summary and the commands the user will want next.
_deploy_report() {
	echo ""
	echo "=== Deploy complete! ==="
	echo ""
	echo "Checking status..."
	adb_root "sh $REMOTE_DIR/focus_ctl.sh status"
	echo ""
	echo "Boot autostart is disabled by default (FOCUS_BOOT_AUTOSTART=0)."
	echo "No Magisk service.d hook is installed unless FOCUS_BOOT_AUTOSTART=1 in config.sh."
	echo "Launcher enforcement does not auto-start on boot unless LAUNCHER_BOOT_AUTOSTART=1 is set in config.sh."
	echo ""
	echo "Useful commands:"
	echo "  $0 $PHONE_IP --status      # Check mode and location"
	echo "  $0 $PHONE_IP --log         # View daemon log"
	echo "  $0 $PHONE_IP --list        # See all apps and whitelist status"
	echo "  $0 $PHONE_IP --enable      # Force focus mode on for testing"
	echo "  $0 $PHONE_IP --disable     # Force focus mode off"
	echo "  $0 $PHONE_IP --install-aurora  # Install Aurora Store (Play Store alternative)"
}
