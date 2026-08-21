#!/usr/bin/env bash
# lib/tests/mtk_harness.sh — shared fixture for linux_configuration/scripts/lib.
#
# Sourced, not executed.
#
# WHAT IS EXERCISED
#   The pure decision logic and everything reachable through the
#   MTK_ROOT_FIXTURE seam that mtk_common.sh documents as its only boundary
#   with real hardware: classify_device, discover_partitions,
#   mtk_ramdisk_carrier, mtk_check_layout_expectation, mtk_assert_mediatek,
#   mtk_sanitize, mtk_sane_ramdisk_size, mtk_select_device/require_authorized
#   under a fixture, plus the string helpers in common_datetime.sh.
#
# WHAT IS DELIBERATELY NOT EXERCISED, AND WHY
#   The coverage gate only checks that this directory HAS a run_all.sh, so it
#   cannot tell a real suite from an empty one. Naming the gaps is therefore
#   the only honest record of them:
#     - require_hosts_readable / init_android_script — `exec sudo -E bash "$0"`
#       would replace the test process with a sudo re-exec of the suite.
#     - check_adb_device / check_adb_root — call die(), which exits 1 and
#       would take the whole run down; both also need real hardware.
#     - collapse_mounts — calls `umount -l` on a live path.
#     - install_missing_pacman_packages / require_imagemagick / notify —
#       effecting code (pacman, desktop notifications).
#     - mtk_udev_catchall_files — globs /etc/udev/rules.d with no seam, so it
#       reads this host's real rules; the result differs between here and CI.
#     - mtk_sha256 / mtk_file_size — one-line wrappers over sha256sum/stat.
#   This matches Phase 1's measured pattern: decision logic reaches ~90%, the
#   effecting code reaches 0%.
#
# TIME AND HOST DEPENDENCE
#   This suite runs in shell-tests.yml and again on every pre-push via
#   ci-mirror, so a wall-clock assertion would pass locally and fail at some
#   other hour on some other machine. get_hour and get_day_of_week are
#   therefore shimmed where a specific value is needed, and the readers of
#   /proc/uptime are asserted on SHAPE, never on value.
set -euo pipefail

PASS=0
FAIL=0

_t_ok() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_bad() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

# Assert equality. Every check in this suite funnels through here or _t_rc so
# there is exactly one place that counts a result.
_t_is() {
	if [[ $2 == "$1" ]]; then
		_t_ok "$3"
	else
		_t_bad "$3 (want '${1}', got '${2}')"
	fi
}

# Assert a command's exit status. Run under `if` so a non-zero return is data
# rather than a `set -e` abort.
_t_rc() {
	local want="$1" what="$2"
	shift 2
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	_t_is "$want" "$got" "$what"
}

# Assert a substring, for messages whose exact wording is not the contract.
_t_in() {
	if [[ $2 == *"$1"* ]]; then
		_t_ok "$3"
	else
		_t_bad "$3 (want substring '${1}')"
	fi
}

# ---------------------------------------------------------------------------
# Isolation
# ---------------------------------------------------------------------------

# android.sh runs `ensure_dir "$ANDROID_WORK_DIR"` at SOURCE time, and that
# path is under $HOME. Redirect HOME before sourcing anything or merely
# loading the library writes to the real ~/.cache. MTK_ROOT_CACHE moves the
# mtk toolkit's artifacts for the same reason.
_t_sandbox() {
	T_TMP="$(mktemp -d)"
	export T_TMP
	HOME="$T_TMP/home"
	mkdir -p "$HOME"
	export HOME
	export MTK_ROOT_CACHE="$T_TMP/cache"
}

_t_cleanup() {
	[[ -n ${T_TMP:-} && -d ${T_TMP:-} ]] && rm -rf "$T_TMP"
	return 0
}

# Build a device fixture. mtk_common.sh reads props.txt as `key=value` lines
# and by-name.txt as one partition per line; those two files ARE the seam.
# Usage: _t_fixture <name> <props-text> <by-name-text>
_t_fixture() {
	local dir="$T_TMP/fixtures/$1"
	mkdir -p "$dir"
	printf '%s\n' "$2" >"$dir/props.txt"
	printf '%s\n' "$3" >"$dir/by-name.txt"
	printf '%s' "$dir"
}

# Report and set the process exit status. Called at the end of every suite.
_t_done() {
	printf '\n  %s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
	_t_cleanup
	[[ $FAIL -eq 0 ]]
}
