#!/system/bin/sh
# shellcheck shell=ash
# ctl_usage.sh — focus_ctl.sh's help text and the two commands that report on
# the whitelist: list-apps and whitelist.
#
# A flat sibling, not lib/: deploy.sh pushes phone scripts into one directory.
# Sourced by focus_ctl.sh, which owns the config.sh globals these read.
#
# NOTE on iter_whitelist_packages: its `while read` loop is fed by a pipe from
# printf, and nothing in the body reads stdin, so the pipe is safe here. That
# is NOT true of the pm-driven loops elsewhere in this repo -- see the warning
# in daemon_apps.sh before converting any redirect-driven loop to a pipe.

# Emit one valid package name per line from WHITELIST.
# This strips comments/blank lines from the multi-line quoted string and avoids
# treating heading text (e.g. "---") as package tokens.
iter_whitelist_packages() {
	printf '%s\n' "$WHITELIST" | while IFS= read -r line; do
		line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		# Blank lines only. A comment needs no case of its own: `set -- $line`
		# below splits on whitespace, so a comment's first token is always "#",
		# which the dot check then rejects. A dedicated `\#*)` arm here was
		# provably equivalent -- a mutation removing it could not be
		# distinguished by any input -- and equivalent code is a claim of a
		# check that is not actually being made.
		case "$line" in
		"") continue ;;
		esac

		# Keep first token only; ignore any inline prose if present.
		# Intentional word split to grab the first token. This runs under
		# /system/bin/sh on the phone, where arrays do not exist, so an
		# unquoted expansion is the POSIX way to do it.
		# shellcheck disable=SC2086
		set -- $line
		pkg="$1"

		# Package names are dot-delimited identifiers.
		case "$pkg" in
		*.*) ;;
		*) continue ;;
		esac
		case "$pkg" in
		*[!A-Za-z0-9._]*) continue ;;
		esac

		echo "$pkg"
	done
}

usage() {
	echo "Usage: focus_ctl.sh <command>"
	echo ""
	echo "Commands:"
	echo "  start      - Start the focus mode daemon"
	echo "  stop       - Stop the daemon and re-enable all apps"
	echo "  status     - Show current mode, location and disabled apps"
	echo "  enable     - Force focus mode on (regardless of location)"
	echo "  disable    - Force focus mode off (regardless of location)"
	echo "  log        - Show daemon log"
	echo "  list-apps  - List all non-whitelisted third-party apps"
	echo "  whitelist  - List currently whitelisted packages"
	echo "  restart    - Restart the daemon"
	echo "  hosts-status   - Show hosts enforcer state (mount + hash)"
	echo "  hosts-start    - Start the hosts enforcer daemon"
	echo "  hosts-stop     - Stop the hosts enforcer daemon"
	echo "  hosts-log      - Show hosts enforcer log"
	echo "  dns-status     - Show DNS enforcer state (Private DNS + iptables)"
	echo "  dns-start      - Start the DNS enforcer daemon"
	echo "  dns-stop       - Stop the DNS enforcer daemon (removes iptables chain)"
	echo "  dns-log        - Show DNS enforcer log"
	echo "  launcher-status  - Show launcher enforcer state"
	echo "  launcher-start   - Start the launcher enforcer daemon"
	echo "  launcher-stop    - Stop the launcher enforcer daemon"
	echo "  launcher-log     - Show launcher enforcer log"
	echo "  launcher-snapshot - Back up currently-installed launcher APK"
	echo "  workout-status   - Show StrongLifts workout-detection state"
	echo "  workout-start    - Start the workout detector daemon"
	echo "  workout-stop     - Stop the workout detector daemon (sets flag=0)"
	echo "  workout-log      - Show workout detector log"
	echo "  recheck    - Nudge the daemon to perform a fresh location check now"
	echo "  curfew-status    - Show night-curfew + enforcer state"
	echo "  curfew-start     - Start the curfew enforcer (grayscale/DND/net)"
	echo "  curfew-stop      - Stop it and restore daytime display/DND"
	echo "  curfew-log       - Show curfew enforcer log"
	echo "  curfew-test-on   - Force curfew ACTIVE now (daytime validation)"
	echo "  curfew-test-off  - Clear the test force"
	echo "  curfew-demo-on   - Start a demo: full curfew now, easy one-tap off"
	echo "  curfew-demo-off  - Stop the demo"
	echo "  curfew-off       - Escape hatch: suspend curfew now (2am opt-out)"
	echo "  curfew-on        - Re-arm curfew (clear the override)"
	echo "  tether-status    - Show hotspot/tethering-block state"
	echo "  tether-start     - Start the tether enforcer (FORWARD block + offload off)"
	echo "  tether-stop      - Stop it and restore tethering (teardown FORWARD chain)"
	echo "  tether-log       - Show tether enforcer log"
	echo "  tether-test-on   - Force the tether block ACTIVE now (daytime validation)"
	echo "  tether-test-off  - Clear the tether force"
	echo "  notif-status - Show companion status-notification details"
	echo ""
}

cmd_list_apps() {
	echo "=== Third-party apps NOT in whitelist ==="
	for pkg in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
		whitelisted=0
		for w in $(iter_whitelist_packages); do
			w="$(echo "$w" | tr -d '[:space:]')"
			[ -z "$w" ] && continue
			[ "$pkg" = "$w" ] && {
				whitelisted=1
				break
			}
		done
		if [ "$whitelisted" -eq 0 ]; then
			# Check if currently disabled by focus mode
			if grep -qF "$pkg" "$DISABLED_APPS_FILE" 2>/dev/null; then
				echo "  [BLOCKED] $pkg"
			else
				echo "  [active]  $pkg"
			fi
		fi
	done
	echo ""
	echo "=== Whitelisted apps ==="
	for w in $(iter_whitelist_packages); do
		w="$(echo "$w" | tr -d '[:space:]')"
		[ -z "$w" ] && continue
		echo "  [allowed] $w"
	done
}

cmd_whitelist() {
	echo "=== Whitelisted packages ==="
	for w in $(iter_whitelist_packages); do
		w="$(echo "$w" | tr -d '[:space:]')"
		[ -z "$w" ] && continue
		# Check if installed
		if pm list packages "$w" 2>/dev/null | grep -qF "$w"; then
			echo "  [installed] $w"
		else
			echo "  [not found] $w"
		fi
	done
}
