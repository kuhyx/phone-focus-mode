#!/bin/bash
# deploy_install.sh — copying the staged files into $REMOTE_DIR and setting
# their permissions.
#
# Sourced by deploy.sh, which owns adb_root and $REMOTE_DIR.
#
# _deploy_install_files holds the SECOND of the two hardcoded file lists; the
# first is the push list in deploy_phases.sh. Keep them in step: a file in one
# and not the other is the failure mode this comment exists to prevent.

# Copy everything from the staging directory into $REMOTE_DIR. This is
# the SECOND of the two hardcoded lists -- a sibling added to the push
# list in _deploy_push_scripts must be added here too, or it is staged
# and never lands.
_deploy_install_files() {
	adb_root "cp /data/local/tmp/focus_stage/config.sh             $REMOTE_DIR/config.sh"
	adb_root "cp /data/local/tmp/focus_stage/config_paths.sh       $REMOTE_DIR/config_paths.sh"
	adb_root "cp /data/local/tmp/focus_stage/config_dns.sh         $REMOTE_DIR/config_dns.sh"
	adb_root "cp /data/local/tmp/focus_stage/config_curfew.sh      $REMOTE_DIR/config_curfew.sh"
	adb_root "cp /data/local/tmp/focus_stage/config_tether.sh      $REMOTE_DIR/config_tether.sh"
	adb_root "cp /data/local/tmp/focus_stage/config_launcher.sh    $REMOTE_DIR/config_launcher.sh"
	adb_root "cp /data/local/tmp/focus_stage/focus_daemon.sh       $REMOTE_DIR/focus_daemon.sh"
	adb_root "cp /data/local/tmp/focus_stage/daemon_location.sh    $REMOTE_DIR/daemon_location.sh"
	adb_root "cp /data/local/tmp/focus_stage/daemon_state.sh       $REMOTE_DIR/daemon_state.sh"
	adb_root "cp /data/local/tmp/focus_stage/daemon_apps.sh        $REMOTE_DIR/daemon_apps.sh"
	adb_root "cp /data/local/tmp/focus_stage/focus_ctl.sh          $REMOTE_DIR/focus_ctl.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_usage.sh          $REMOTE_DIR/ctl_usage.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_daemon.sh         $REMOTE_DIR/ctl_daemon.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_hosts.sh          $REMOTE_DIR/ctl_hosts.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_dns.sh            $REMOTE_DIR/ctl_dns.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_launcher.sh       $REMOTE_DIR/ctl_launcher.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_workout.sh        $REMOTE_DIR/ctl_workout.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_curfew.sh         $REMOTE_DIR/ctl_curfew.sh"
	adb_root "cp /data/local/tmp/focus_stage/ctl_tether.sh         $REMOTE_DIR/ctl_tether.sh"
	adb_root "cp /data/local/tmp/focus_stage/hosts_enforcer.sh     $REMOTE_DIR/hosts_enforcer.sh"
	adb_root "cp /data/local/tmp/focus_stage/hosts_magisk.sh       $REMOTE_DIR/hosts_magisk.sh"
	adb_root "cp /data/local/tmp/focus_stage/hosts_mount.sh        $REMOTE_DIR/hosts_mount.sh"
	adb_root "cp /data/local/tmp/focus_stage/dns_enforcer.sh       $REMOTE_DIR/dns_enforcer.sh"
	adb_root "cp /data/local/tmp/focus_stage/dns_iptables.sh      $REMOTE_DIR/dns_iptables.sh"
	adb_root "cp /data/local/tmp/focus_stage/launcher_enforcer.sh  $REMOTE_DIR/launcher_enforcer.sh"
	adb_root "cp /data/local/tmp/focus_stage/curfew_enforcer.sh    $REMOTE_DIR/curfew_enforcer.sh"
	adb_root "cp /data/local/tmp/focus_stage/curfew_net.sh         $REMOTE_DIR/curfew_net.sh"
	adb_root "cp /data/local/tmp/focus_stage/tether_enforcer.sh    $REMOTE_DIR/tether_enforcer.sh"
	adb_root "cp /data/local/tmp/focus_stage/tether_iptables.sh    $REMOTE_DIR/tether_iptables.sh"
	adb_root "cp /data/local/tmp/focus_stage/workout_detector.sh   $REMOTE_DIR/workout_detector.sh"
	if adb_cmd shell "test -f /data/local/tmp/focus_stage/sqlite3" 2>/dev/null; then
		adb_root "cp /data/local/tmp/focus_stage/sqlite3 $REMOTE_DIR/sqlite3"
		adb_root "chmod 0755 $REMOTE_DIR/sqlite3"
	fi
	if grep -q '^export FOCUS_BOOT_AUTOSTART=1' "$DEPLOY_DIR/config.sh"; then
		adb_root "cp /data/local/tmp/focus_stage/99-focus-mode.sh      /data/adb/service.d/99-focus-mode.sh"
	else
		adb_root "rm -f /data/adb/service.d/99-focus-mode.sh /data/adb/service.d/99-focus-mode.sh.disabled"
	fi
	# Install canonical hosts and lock it down (only if generator produced it).
	if adb_cmd shell "test -f /data/local/tmp/focus_stage/hosts.canonical" 2>/dev/null; then
		# chattr -i first so we can overwrite a previously-locked canonical
		adb_root "chattr -i $REMOTE_DIR/hosts.canonical 2>/dev/null; true"
		adb_root "cp /data/local/tmp/focus_stage/hosts.canonical $REMOTE_DIR/hosts.canonical"
		adb_root "chmod 644 $REMOTE_DIR/hosts.canonical"
		# Pre-compute the sha so the enforcer does not have to seed it.
		adb_root "chattr -i $REMOTE_DIR/hosts.sha256 2>/dev/null; true"
		adb_root "cp /data/local/tmp/focus_stage/hosts.sha256 $REMOTE_DIR/hosts.sha256"
		adb_root "chmod 644 $REMOTE_DIR/hosts.sha256"
		adb_root "chattr +i $REMOTE_DIR/hosts.canonical 2>/dev/null; true"
		adb_root "chattr +i $REMOTE_DIR/hosts.sha256 2>/dev/null; true"

		# ---- Workout-variant canonical (optional) ----
		# Same lockdown treatment as the full canonical. Pushed by the workout
		# hosts generator block above. Missing variant means workout_detector\
		# will simply have no relaxed file to swap to (hosts_enforcer falls\
		# back to the full canonical).
		if adb_cmd shell "test -f /data/local/tmp/focus_stage/hosts.canonical.workout" 2>/dev/null; then
			adb_root "chattr -i $REMOTE_DIR/hosts.canonical.workout 2>/dev/null; true"
			adb_root "cp /data/local/tmp/focus_stage/hosts.canonical.workout $REMOTE_DIR/hosts.canonical.workout"
			adb_root "chmod 644 $REMOTE_DIR/hosts.canonical.workout"
			adb_root "chattr -i $REMOTE_DIR/hosts.sha256.workout 2>/dev/null; true"
			adb_root "cp /data/local/tmp/focus_stage/hosts.sha256.workout $REMOTE_DIR/hosts.sha256.workout"
			adb_root "chmod 644 $REMOTE_DIR/hosts.sha256.workout"
			adb_root "chattr +i $REMOTE_DIR/hosts.canonical.workout 2>/dev/null; true"
			adb_root "chattr +i $REMOTE_DIR/hosts.sha256.workout 2>/dev/null; true"
		fi

		# Magisk Systemless Hosts module was ensured (and rebooted if needed) in
		# step [2.5] above.  Sanity-assert it's still active before writing to it.
		if ! adb_root "test -f /system/etc/hosts" 2>/dev/null; then
			echo "ERROR: /system/etc/hosts not magic-mounted — run deploy again."
			exit 1
		fi

		adb_root "mkdir -p /data/adb/modules/hosts/system/etc"
		# Drop any +i lock the runtime hosts_enforcer may have set on the
		# module dir / hosts file so we can update them. The enforcer will
		# re-lock on its next poll cycle. Also pre-emptively delete any
		# disable/remove markers that may exist on disk before we start.
		adb_root "chattr -i /data/adb/modules/hosts /data/adb/modules/hosts/system/etc/hosts 2>/dev/null; rm -f /data/adb/modules/hosts/disable /data/adb/modules/hosts/remove /data/adb/modules/hosts/update; true"
		adb_root "cp $REMOTE_DIR/hosts.canonical /data/adb/modules/hosts/system/etc/hosts"
		adb_root "chmod 644 /data/adb/modules/hosts/system/etc/hosts"
		# Lock the module dir to block the Magisk app's "Disable" / "Remove"
		# buttons (they create marker files inside the dir). Files already
		# in the dir stay mutable so the runtime enforcer can still update
		# the hosts file on workout state changes.
		adb_root "chattr +i /data/adb/modules/hosts/system/etc/hosts 2>/dev/null; true"
		adb_root "chattr +i /data/adb/modules/hosts 2>/dev/null; true"
		echo "  Magisk hosts module populated ($(adb_root "wc -l < /data/adb/modules/hosts/system/etc/hosts" 2>/dev/null | tr -d ' ') lines), locked against UI-disable. Reboot to activate /system/etc/hosts."
	fi
	adb_root "rm -rf /data/local/tmp/focus_stage"

	# Flush in-process DNS caches of browsers. Apps like Firefox and Chrome
	# cache resolved IPs internally and bypass /etc/hosts until restarted.
	echo "  Flushing browser DNS caches..."
	# BROWSER_PACKAGES is set by the top-level `. config.sh` above and is never
	# modified. shellcheck only flags it because config.sh is ALSO re-sourced
	# inside a subshell further up (to re-read WORKOUT_UNBLOCK_DOMAINS from the
	# freshly-staged copy); that subshell's assignments are discarded by design.
	# The unquoted expansion is the intended word split over the package list.
	# shellcheck disable=SC2031
	for _pkg in $BROWSER_PACKAGES; do
		[ -n "$_pkg" ] || continue
		adb_root "am force-stop '$_pkg' 2>/dev/null; true"
		echo "    force-stopped $_pkg"
	done

	# Disable Firefox DNS-over-HTTPS via user.js. Firefox uses hardcoded
	# Cloudflare bootstrap IPs (104.16.248.249, 104.16.249.249) to reach
	# mozilla.cloudflare-dns.com, completely bypassing /etc/hosts even
	# after a fresh start. TRR mode 5 disables DoH so Firefox falls back
	# to the system resolver which sees our 0.0.0.0 blocks.
	echo "  Disabling Firefox DNS-over-HTTPS..."
	adb_root "for _p in /data/data/org.mozilla.fenix/files/mozilla/*/; do
        [ -f \"\${_p}prefs.js\" ] || continue
        grep -qF '\"network.trr.mode\"' \"\${_p}user.js\" 2>/dev/null \
            || { printf 'user_pref(\"network.trr.mode\", 5);\\n' >> \"\${_p}user.js\" 2>/dev/null && echo \"  Wrote DoH-disable pref to \${_p}user.js\"; }
    done; true"

	_deploy_set_permissions
}

# Phase 5: make the staged scripts executable and their logs writable.
_deploy_set_permissions() {
	echo "[5/7] Setting permissions..."
	adb_root "chmod 755 $REMOTE_DIR/config.sh $REMOTE_DIR/focus_daemon.sh $REMOTE_DIR/focus_ctl.sh $REMOTE_DIR/hosts_enforcer.sh $REMOTE_DIR/dns_enforcer.sh $REMOTE_DIR/launcher_enforcer.sh $REMOTE_DIR/curfew_enforcer.sh $REMOTE_DIR/tether_enforcer.sh $REMOTE_DIR/workout_detector.sh" || true
	if grep -q '^export FOCUS_BOOT_AUTOSTART=1' "$DEPLOY_DIR/config.sh"; then
		adb_root "chmod 755 /data/adb/service.d/99-focus-mode.sh"
	fi
	adb_root "touch $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log $REMOTE_DIR/tether_enforcer.log $REMOTE_DIR/workout_detector.log"
	# State files need 666 so the daemons can write regardless of SELinux context drift
	adb_root "chmod 666 $REMOTE_DIR/disabled_by_focus.txt $REMOTE_DIR/focus_mode.log $REMOTE_DIR/hosts_enforcer.log $REMOTE_DIR/dns_enforcer.log $REMOTE_DIR/launcher_enforcer.log $REMOTE_DIR/tether_enforcer.log $REMOTE_DIR/workout_detector.log" || true

	_deploy_start_daemons
}
