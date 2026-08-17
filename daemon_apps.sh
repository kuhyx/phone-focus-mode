#!/system/bin/sh
# shellcheck shell=ash
# daemon_apps.sh — the app layer of focus_daemon.sh: deciding whether a
# package is allowed, disabling everything that is not while focus mode is on,
# and re-enabling it afterwards.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory.
#
# Sourced by focus_daemon.sh, which owns log(), $CURRENT_MODE (written here
# and in init, read by main, so it stays with them) and the config.sh globals
# these read ($DISABLED_APPS_FILE, $MODE_FILE, $STATE_DIR).
#
# NOTE for anyone editing the `while IFS= read -r pkg; do ... done <file`
# loops below: they must stay redirect-driven. Every body calls pm, which
# inherits and drains the loop's stdin if the file is piped in instead — the
# measured symptom elsewhere in this repo was processing 1 package of 54.

reconcile_disabled_apps() {
	[ -f "$DISABLED_APPS_FILE" ] || return

	local tmp_disabled="$STATE_DIR/disabled_by_focus.tmp"
	: >"$tmp_disabled"

	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue

		if is_allowed "$pkg"; then
			pm install-existing --user 0 "$pkg" >/dev/null 2>&1 || true
			pm enable "$pkg" >/dev/null 2>&1 || true
			log "Re-enabled allowed app during state reconciliation: $pkg"
			continue
		fi

		echo "$pkg" >>"$tmp_disabled"
	done <"$DISABLED_APPS_FILE"

	mv "$tmp_disabled" "$DISABLED_APPS_FILE"
}

# ---- Check if package is allowed (whitelist or system-protected) ----
is_allowed() {
	local pkg="$1"
	# During the night curfew, swap the permissive day list for the strict
	# night list. The sysprotect + default-handler guards below still apply on
	# top of whichever list is active.
	local list="$STATE_DIR/whitelist.txt"
	if curfew_active; then
		list="$STATE_DIR/night_whitelist.txt"
	fi
	# Exact match against the active whitelist file
	if grep -qxF "$pkg" "$list" 2>/dev/null; then
		return 0
	fi
	# Prefix match against system-protect file
	while IFS= read -r prefix; do
		[ -z "$prefix" ] && continue
		case "$pkg" in
		"$prefix"*) return 0 ;;
		esac
	done <"$STATE_DIR/sysprotect.txt"
	# Hard-stop guard: refuse to disable any package that is the current
	# default handler for a critical role (Dialer / SMS / Home / Contacts).
	# Without this, a misconfigured WHITELIST can disable the default Phone
	# app and Android falls back to com.android.settings/.FallbackHome -
	# the persistent "Phone is starting..." screen with broken SystemUI
	# gestures (no swipe-up recents). Recovering requires `pm enable` over
	# ADB. Treat the guard as last-resort safety net independent of WHITELIST
	# contents so a future config edit can never wipe these out.
	is_default_handler "$pkg" && return 0
	# The default browser is guarded only OUTSIDE curfew. At night the whole
	# point is to disable browsers, so this guard must not re-allow it.
	if ! curfew_active &&
		grep -qxF "$pkg" "$STATE_DIR/default_browser.txt" 2>/dev/null; then
		return 0
	fi
	return 1
}

enable_focus_mode() {
	local first_entry=0
	if [ "$CURRENT_MODE" != "focus" ]; then
		first_entry=1
		log "ENABLING focus mode - restricting non-whitelisted apps"
		: >"$DISABLED_APPS_FILE"
	fi

	# Refresh default-handler list every tick. The user may switch dialer /
	# SMS / launcher between sweeps; the guard in is_allowed() consults this
	# list so a newly-promoted handler is never disabled.
	refresh_default_handlers

	# Blocked system app list is static; built once in init() (see
	# build_blocked_sys_file), not rebuilt on every sweep.
	local blocked_sys="$STATE_DIR/blocked_sys.txt"

	# Periodic rescan catches third-party apps the user re-enabled (e.g. via
	# Play Store or `pm enable` in a terminal) since the last tick.
	# -e = enabled only, so we skip apps that are already disabled.
	local tmp_pkgs="$STATE_DIR/pkg_list.txt"
	pm list packages -3 -e 2>/dev/null | sed 's/^package://' >"$tmp_pkgs"
	local newly_disabled=0
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		is_allowed "$pkg" && continue
		if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
			grep -qxF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null ||
				echo "$pkg" >>"$DISABLED_APPS_FILE"
			newly_disabled=$((newly_disabled + 1))
		fi
	done <"$tmp_pkgs"
	rm -f "$tmp_pkgs"

	# Disable-for-user-0 any blocked system apps (Play Store, browsers,
	# package installer UI, terminal apps).
	# IMPORTANT: We intentionally use pm disable-user (NOT pm uninstall) here.
	# pm uninstall -k --user 0 removes the package from Android's user-0
	# package registry. If the daemon is killed with SIGKILL during a reboot
	# (bypassing the cleanup trap), those packages stay uninstalled across the
	# reboot. Android's bootloop-protection (MTK and others) then detects
	# missing critical system packages and triggers recovery / factory wipe.
	# pm disable-user leaves the package registered but inactive, so the
	# PackageManager scan at next boot succeeds and no wipe occurs.
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
			grep -qxF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null ||
				echo "$pkg" >>"$DISABLED_APPS_FILE"
			newly_disabled=$((newly_disabled + 1))
		fi
	done <"$blocked_sys"

	CURRENT_MODE="focus"
	echo "focus" >"$MODE_FILE"

	if [ "$first_entry" -eq 1 ]; then
		local count
		count=$(wc -l <"$DISABLED_APPS_FILE" 2>/dev/null || echo 0)
		log "Focus mode enabled - disabled $count apps"
	elif [ "$newly_disabled" -gt 0 ]; then
		log "Focus mode re-sweep: re-disabled $newly_disabled apps (re-enabled by user?)"
	fi

	reconcile_disabled_apps
}

disable_focus_mode() {
	[ "$CURRENT_MODE" = "normal" ] && return
	log "DISABLING focus mode - re-enabling apps"

	local count=0
	if [ -f "$DISABLED_APPS_FILE" ] && [ -s "$DISABLED_APPS_FILE" ]; then
		# Re-enable all disabled apps (both 3rd-party and system apps).
		# Both paths now use pm disable-user, so pm enable is the only
		# restore command needed.
		while IFS= read -r pkg; do
			[ -z "$pkg" ] && continue
			pm enable "$pkg" >/dev/null 2>&1 && count=$((count + 1))
		done <"$DISABLED_APPS_FILE"
		: >"$DISABLED_APPS_FILE"
	fi

	CURRENT_MODE="normal"
	echo "normal" >"$MODE_FILE"
	log "Focus mode disabled - re-enabled $count apps"
}
