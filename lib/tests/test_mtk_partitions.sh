#!/usr/bin/env bash
# Covers discover_partitions, mtk_ramdisk_carrier,
# mtk_check_layout_expectation, mtk_sane_ramdisk_size and mtk_check_venv.
#
# The load-bearing case is INIT_BOOT WINS OVER BOOT. A device launched on
# Android 13+ carries the ramdisk in init_boot even though boot also exists,
# so a loop that checked boot first would pick the wrong partition on exactly
# the hardware this toolkit targets — and would do it silently, because both
# names are present and both reads succeed.
#
# The second is that discover_partitions consults the FILESYSTEM, never the
# API level. mtk_check_layout_expectation may disagree and warn, but it must
# not change the answer.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mtk_harness.sh
source "$HERE/mtk_harness.sh"

_t_sandbox
# shellcheck source=../mtk_common.sh
source "$HERE/../mtk_common.sh"

# --- discover_partitions ---------------------------------------------------

# A/B device with init_boot: the ramdisk lives in init_boot, not boot.
MTK_ROOT_FIXTURE="$(_t_fixture ab_initboot 'ro.boot.slot_suffix=_a' \
	'boot_a
boot_b
init_boot_a
init_boot_b
vbmeta_a
vbmeta_b
userdata')"
export MTK_ROOT_FIXTURE
_t_rc 0 "discover_partitions succeeds when a ramdisk carrier exists" discover_partitions
discover_partitions
_t_is "A/B" "$MTK_AB_SCHEME" "an _a suffix in the listing means A/B"
_t_is "_a" "$MTK_SLOT_SUFFIX" "slot suffix comes from ro.boot.slot_suffix"
_t_is "init_boot_a" "$MTK_RAMDISK_PART" "init_boot wins over boot when both exist"
_t_is "vbmeta_a" "$MTK_VBMETA_PART" "vbmeta picks up the active slot suffix"
_t_is "init_boot" "$(mtk_ramdisk_carrier)" "carrier strips the slot suffix"
_t_is "0" "$MTK_SLOT_ASSUMED" "a reported slot suffix is not an assumption"

# A-only device with no init_boot: must fall through to boot.
MTK_ROOT_FIXTURE="$(_t_fixture aonly_boot '' \
	'boot
recovery
vbmeta
userdata')"
discover_partitions
_t_is "A-only" "$MTK_AB_SCHEME" "no _a suffix means A-only"
_t_is "" "$MTK_SLOT_SUFFIX" "A-only has no slot suffix"
_t_is "boot" "$MTK_RAMDISK_PART" "falls through to boot when init_boot is absent"
_t_is "boot" "$(mtk_ramdisk_carrier)" "carrier of an unsuffixed boot is boot"

# A/B device whose slot_suffix is unreadable. The code falls back to _a
# because a dump has to start somewhere, but must FLAG that it guessed.
MTK_ROOT_FIXTURE="$(_t_fixture ab_no_suffix '' \
	'boot_a
boot_b
vbmeta_a
vbmeta_b')"
discover_partitions
_t_is "_a" "$MTK_SLOT_SUFFIX" "A/B with no reported suffix falls back to _a"
_t_is "1" "$MTK_SLOT_ASSUMED" "the _a fallback is recorded as an assumption"
_t_is "boot_a" "$MTK_RAMDISK_PART" "assumed suffix still resolves a carrier"

# An empty listing is what an unauthorized or absent device produces. It must
# fail rather than reporting a plausible-looking empty layout.
MTK_ROOT_FIXTURE="$(_t_fixture no_partitions '' '')"
_t_rc 1 "discover_partitions fails on an empty by-name listing" discover_partitions
discover_partitions || true
_t_is "unknown" "$MTK_AB_SCHEME" "an empty listing yields an unknown scheme"
_t_is "" "$MTK_RAMDISK_PART" "an empty listing names no ramdisk partition"

# A listing with neither boot nor init_boot: non-empty, but no carrier.
MTK_ROOT_FIXTURE="$(_t_fixture no_carrier '' \
	'system
vendor
userdata')"
_t_rc 1 "discover_partitions fails when no carrier is present" discover_partitions

# --- mtk_check_layout_expectation ------------------------------------------

# first_api_level >= 33 predicts init_boot. Agreement is quiet.
MTK_ROOT_FIXTURE="$(_t_fixture api34_initboot \
	'ro.boot.slot_suffix=_a
ro.product.first_api_level=34' \
	'boot_a
init_boot_a')"
discover_partitions
_t_rc 0 "api 34 + init_boot carrier agrees" mtk_check_layout_expectation

# Disagreement warns and returns 1 — but the device still wins.
MTK_ROOT_FIXTURE="$(_t_fixture api34_boot_only \
	'ro.boot.slot_suffix=_a
ro.product.first_api_level=34' \
	'boot_a
vbmeta_a')"
discover_partitions
_t_rc 1 "api 34 + boot carrier disagrees and says so" mtk_check_layout_expectation
_t_is "boot_a" "$MTK_RAMDISK_PART" "a disagreeing expectation does NOT change the answer"
warn_out="$(mtk_check_layout_expectation 2>&1 || true)"
_t_in "Trusting the device" "$warn_out" "the warning states the filesystem wins"

# Below 33 predicts boot.
MTK_ROOT_FIXTURE="$(_t_fixture api30_boot 'ro.product.first_api_level=30' 'boot')"
discover_partitions
_t_rc 0 "api 30 + boot carrier agrees" mtk_check_layout_expectation

# An unreadable or non-numeric api level is not an error — it is simply no
# cross-check. This must not be mistaken for a disagreement.
MTK_ROOT_FIXTURE="$(_t_fixture api_missing '' 'boot')"
discover_partitions
_t_rc 0 "an absent api level skips the cross-check" mtk_check_layout_expectation

# --- mtk_sane_ramdisk_size -------------------------------------------------

# Both an empty read and a whole-disk grab look like success to mtkclient's
# exit code, which is the entire reason this band exists.
_t_rc 1 "zero bytes is implausible" mtk_sane_ramdisk_size 0
_t_in "implausibly small" "$(mtk_sane_ramdisk_size 0 || true)" "small failure says which way"
_t_rc 1 "a truncated read is implausible" mtk_sane_ramdisk_size 1024
_t_rc 0 "8 MiB is a plausible ramdisk" mtk_sane_ramdisk_size $((8 * 1024 * 1024))
_t_rc 0 "the lower bound itself is accepted" mtk_sane_ramdisk_size $((1024 * 1024))
_t_rc 0 "the upper bound itself is accepted" mtk_sane_ramdisk_size $((128 * 1024 * 1024))
_t_rc 1 "a whole-disk grab is implausible" mtk_sane_ramdisk_size $((4 * 1024 * 1024 * 1024))
_t_in "implausibly large" "$(mtk_sane_ramdisk_size $((4 * 1024 * 1024 * 1024)) || true)" \
	"large failure says which way"
# `stat` failing yields an empty string, not a number.
_t_rc 1 "a non-numeric size is rejected" mtk_sane_ramdisk_size "not-a-number"
_t_rc 1 "an empty size is rejected" mtk_sane_ramdisk_size ""

# --- mtk_check_venv --------------------------------------------------------

# MTK_ROOT_CACHE points at an empty tmpdir, so this takes the deterministic
# "missing" branch on any host, CI included.
_t_rc 1 "an absent venv is reported as missing" mtk_check_venv
_t_in "missing:" "$(mtk_check_venv || true)" "the missing branch names the interpreter path"

_t_done "test_mtk_partitions.sh"
