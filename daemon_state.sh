#!/system/bin/sh
# shellcheck shell=ash
# daemon_state.sh — the state files focus_daemon.sh derives from config: the
# whitelists, the system-protect and blocked-system lists, the cached default
# intent handlers, and the JSON status snapshot the companion app reads.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory.
#
# Sourced by focus_daemon.sh, which owns log() and the config.sh globals these
# read ($WHITELIST, $NIGHT_WHITELIST, $SYSTEM_NEVER_DISABLE,
# $BLOCKED_SYSTEM_APPS, $STATE_DIR, $STATUS_FILE, $RADIUS). Nothing here is
# assigned, so there is no global to keep in step.

build_whitelist_file() {
	echo "$WHITELIST" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' |
		sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >"$STATE_DIR/whitelist.txt"
	# Sanity check: the WHITELIST string in config.sh is fragile - any
	# literal double-quote inside a comment will close the heredoc and
	# silently truncate the variable. Log the parsed line count so any
	# future regression is visible in the log, and warn loudly if it
	# falls below a known floor (we always have ~70+ entries).
	local n
	n=$(wc -l <"$STATE_DIR/whitelist.txt" 2>/dev/null | tr -d ' ')
	log "Whitelist parsed: $n entries"
	if [ "${n:-0}" -lt 30 ]; then
		log "WARN: whitelist suspiciously small ($n lines) - check config.sh for stray quotes inside WHITELIST string"
	fi
}

build_night_whitelist_file() {
	# Strict allow-list used while the night curfew is active (see config.sh
	# NIGHT_WHITELIST and is_curfew_now()). Parsed exactly like the day list.
	echo "$NIGHT_WHITELIST" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' |
		sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >"$STATE_DIR/night_whitelist.txt"
	local n
	n=$(wc -l <"$STATE_DIR/night_whitelist.txt" 2>/dev/null | tr -d ' ')
	log "Night-curfew whitelist parsed: $n entries"
	if [ "${n:-0}" -lt 10 ]; then
		log "WARN: night whitelist suspiciously small ($n lines) - check config.sh for stray quotes inside NIGHT_WHITELIST string"
	fi
}

build_sysprotect_file() {
	echo "$SYSTEM_NEVER_DISABLE" | grep -v '^[[:space:]]*$' |
		sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >"$STATE_DIR/sysprotect.txt"
}

# $BLOCKED_SYSTEM_APPS is a static config value (never changes without a
# daemon restart), so - like build_sysprotect_file above - this only needs
# to run once at startup, not every enable_focus_mode() sweep.
build_blocked_sys_file() {
	echo "$BLOCKED_SYSTEM_APPS" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' |
		sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >"$STATE_DIR/blocked_sys.txt"
}

# ---- Default handler detection ----
# Refreshed once per focus_daemon tick into $STATE_DIR/default_handlers.txt.
# Each line is a package name. Lookup is a cheap grep against this file.
refresh_default_handlers() {
	local f="$STATE_DIR/default_handlers.txt"
	local tmp="$f.tmp"
	: >"$tmp"
	# Default Home (launcher). resolve-activity prints "Activity Resolver Table:"
	# on line 1 and "<pkg>/<.Activity>" on line 2 in --brief mode.
	cmd package resolve-activity --brief \
		-c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null |
		awk -F/ 'NR==2 && $1 != "" {print $1}' >>"$tmp"
	# Default Dialer
	local dialer
	dialer="$(cmd telecom get-default-dialer 2>/dev/null | tr -d '[:space:]')"
	[ -n "$dialer" ] && echo "$dialer" >>"$tmp"
	# Default SMS handler (settings provider key)
	local sms
	sms="$(settings get secure sms_default_application 2>/dev/null | tr -d '[:space:]')"
	[ -n "$sms" ] && [ "$sms" != "null" ] && echo "$sms" >>"$tmp"
	# Default input method (active keyboard). Disabling the active IME with
	# pm disable-user PERSISTS across reboot; a 1am reboot would then leave no
	# keyboard to type any recovery command. Protect it day and night so the
	# curfew can never lock you out of typing.
	local ime
	ime="$(settings get secure default_input_method 2>/dev/null | cut -d/ -f1)"
	[ -n "$ime" ] && [ "$ime" != "null" ] && echo "$ime" >>"$tmp"
	sort -u "$tmp" -o "$f"
	rm -f "$tmp"

	# Default Browser handler is tracked SEPARATELY and guarded only OUTSIDE
	# the curfew window (see is_allowed). During curfew the whole point is to
	# disable browsers, so the default-handler guard must not resurrect them.
	local bf="$STATE_DIR/default_browser.txt"
	cmd package resolve-activity --brief \
		-a android.intent.action.VIEW -d http://example.com 2>/dev/null |
		awk -F/ 'NR==2 && $1 != "" {print $1}' >"$bf.tmp" 2>/dev/null
	mv "$bf.tmp" "$bf" 2>/dev/null || : >"$bf"
}

is_default_handler() {
	local pkg="$1"
	grep -qxF "$pkg" "$STATE_DIR/default_handlers.txt" 2>/dev/null
}

# ---- Status snapshot for companion notification app ----
# Writes a tiny JSON file that focus_status_app reads every few seconds.
# Fields: mode, lat, lon, distance_m, threshold_m, radius_m, disabled_count,
# last_check_ts (unix), last_check_iso (human).
write_status_snapshot() {
	local mode="$1" lat="$2" lon="$3" dist="$4" thr="$5"
	local count iso ts cf ov frc
	count="$(wc -l <"$DISABLED_APPS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
	[ -z "$count" ] && count=0
	ts="$(date +%s)"
	iso="$(date '+%Y-%m-%d %H:%M:%S')"
	# Curfew state for the companion app: 1/0 so it slots into the existing
	# numeric JSON path. "curfew" = restrictions active now; "curfew_override"
	# = the escape-hatch file is set (curfew suspended).
	if curfew_active; then cf=1; else cf=0; fi
	if [ -e "$CURFEW_OVERRIDE_FILE" ]; then ov=1; else ov=0; fi
	# "curfew_force" = the demo/test force file is set (curfew forced on
	# regardless of clock). Lets the companion app show Start/Stop demo.
	if [ -e "$CURFEW_FORCE_FILE" ]; then frc=1; else frc=0; fi
	local tmp="$STATUS_FILE.tmp"
	# Shell-emitted JSON — keep values numeric where possible, strings quoted.
	{
		printf '{'
		printf '"mode":"%s",' "$mode"
		printf '"lat":"%s",' "${lat:-}"
		printf '"lon":"%s",' "${lon:-}"
		printf '"distance_m":%s,' "${dist:-null}"
		printf '"threshold_m":%s,' "${thr:-null}"
		printf '"radius_m":%s,' "$RADIUS"
		printf '"disabled_count":%s,' "$count"
		printf '"curfew":%s,' "$cf"
		printf '"curfew_override":%s,' "$ov"
		printf '"curfew_force":%s,' "$frc"
		printf '"last_check_ts":%s,' "$ts"
		printf '"last_check_iso":"%s"' "$iso"
		printf '}\n'
	} >"$tmp" 2>/dev/null || return 0
	mv "$tmp" "$STATUS_FILE" 2>/dev/null || true
	chmod 644 "$STATUS_FILE" 2>/dev/null || true
}
