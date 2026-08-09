#!/bin/bash

# ============================================================================
# Push the home coordinates into focus_owner's private storage.
#
# Why this exists:
#   The geofence needs HOME_LAT/HOME_LON, but those say where the user lives,
#   so they are deliberately absent from the committed policy asset - it is
#   generated with --redact-home. They live in phone_focus_mode/config_secrets.sh,
#   which is gitignored, and are pushed to the device separately.
#
#   The file lands in the app's private data directory, which is not
#   world-readable and does not survive an uninstall. That is the right
#   lifetime: reinstalling should require re-provisioning rather than silently
#   inheriting a stale home.
#
# Usage:
#   ./push_home_location.sh [--serial <id>] [--secrets <path>] [--check]
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly DEFAULT_SERIAL="23181JEGR08034"
readonly PACKAGE="com.kuhy.focus_owner"
readonly REMOTE_NAME="home_location.json"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
readonly REPO_ROOT
SECRETS="$REPO_ROOT/phone_focus_mode/config_secrets.sh"
SERIAL="$DEFAULT_SERIAL"
CHECK_ONLY=0

log() { printf '[home-loc] %s\n' "$1"; }
die() {
	printf '[home-loc] ERROR: %s\n' "$1" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]
  --serial <id>     adb serial (default: $DEFAULT_SERIAL)
  --secrets <path>  config_secrets.sh (default: $SECRETS)
  --check           Report whether coordinates are provisioned; change nothing
  -h, --help        Show this help
EOF
	exit 0
}

adb_sh() { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

require_device() {
	command -v adb >/dev/null 2>&1 || die "adb not found; install android-tools"
	adb -s "$SERIAL" get-state >/dev/null 2>&1 ||
		die "device $SERIAL not connected"
	adb_sh "pm list packages $PACKAGE" | grep -q . ||
		die "$PACKAGE is not installed on $SERIAL"
}

read_coordinate() {
	# Echo one exported coordinate from the secrets file. Deliberately a grep
	# rather than sourcing the file: it holds other secrets, and this script
	# has no business evaluating them.
	local name="$1" raw
	raw="$(grep -oP "(?<=^export ${name}=)[^ #]*" "$SECRETS" | tail -1 | tr -d '"'"'"'')"
	[[ -n "$raw" ]] || die "$name not found in $SECRETS"
	# The shipped secrets file contains REDACTED_* placeholders. Catching that
	# here gives a useful message instead of writing a nonsense coordinate that
	# would silently put "home" wherever the parse happened to land.
	[[ "$raw" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] ||
		die "$name is '$raw', not a coordinate - fill in $SECRETS"
	printf '%s' "$raw"
}

run_check() {
	local out
	out="$(adb_sh "run-as $PACKAGE cat files/$REMOTE_NAME")" || true
	if [[ -z "$out" ]]; then
		log "FAIL no coordinates provisioned"
		return 1
	fi
	# Report presence and shape without echoing the coordinates themselves;
	# this output ends up in terminal scrollback and session transcripts.
	if grep -q '"latitude"' <<<"$out" && grep -q '"longitude"' <<<"$out"; then
		log "OK coordinates provisioned (${#out} bytes)"
		return 0
	fi
	log "FAIL provisioned file is malformed"
	return 1
}

main() {
	require_device
	if [[ $CHECK_ONLY -eq 1 ]]; then
		run_check
		exit $?
	fi

	[[ -f "$SECRETS" ]] || die "secrets file not found: $SECRETS"
	local lat lon tmp
	lat="$(read_coordinate HOME_LAT)"
	lon="$(read_coordinate HOME_LON)"

	tmp="$(mktemp)"
	# shellcheck disable=SC2064  # expand $tmp now, not at trap time
	trap "rm -f '$tmp'" EXIT
	printf '{"latitude": %s, "longitude": %s}\n' "$lat" "$lon" >"$tmp"

	# Staged via /data/local/tmp because adb push cannot write into another
	# app's private directory; run-as then moves it in as the app's own uid.
	adb -s "$SERIAL" push "$tmp" "/data/local/tmp/$REMOTE_NAME" >/dev/null ||
		die "adb push failed"
	# chmod 600 because the default umask leaves it 666. The directory is
	# already private, so this is belt-and-braces rather than the only barrier,
	# but a world-writable file holding the geofence anchor is worth avoiding.
	adb_sh "run-as $PACKAGE sh -c 'mkdir -p files && cat /data/local/tmp/$REMOTE_NAME > files/$REMOTE_NAME && chmod 600 files/$REMOTE_NAME'" ||
		die "run-as failed - is this a debuggable build?"
	adb_sh "rm -f /data/local/tmp/$REMOTE_NAME"
	log "Coordinates written to $PACKAGE private storage"
	run_check
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--serial)
		SERIAL="$2"
		shift 2
		;;
	--secrets)
		SECRETS="$2"
		shift 2
		;;
	--check)
		CHECK_ONLY=1
		shift
		;;
	-h | --help) usage ;;
	*) die "Unknown option: $1" ;;
	esac
done

main "$@"
