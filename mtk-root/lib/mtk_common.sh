#!/bin/bash

# ============================================================================
# mtk_common.sh - Shared helpers for the mtk_root toolkit.
#
# Source this file; do not execute it directly.
#
# Every read from a device goes through dev_getprop() or dev_list_by_name().
# Those two functions are the ONLY seam between the toolkit and real hardware:
# when MTK_ROOT_FIXTURE points at a directory they read text files instead of
# talking to adb, which is what makes the whole test suite offline and
# hermetic. If you add a new device read, route it through these or the tests
# stop meaning anything.
# ============================================================================

# ----------------------------------------------------------------------------
# Device classification patterns.
#
# The Ulefone values are GUESSED - the device has not arrived. If it reports
# something outside these patterns, classify_device returns UNKNOWN and every
# caller refuses to act. That is the intended failure mode, but on day one it
# will look like a bug: run `10-recon.sh --explain-classification` to see which
# predicate missed, then fix the pattern here. This is the one block that
# should need editing when the hardware lands.
# ----------------------------------------------------------------------------
readonly MTK_PLATFORM_PATTERN='^mt[0-9]{4}'
readonly ULEFONE_VENDOR_PATTERN='[Uu]lefone'
readonly ULEFONE_MODEL_PATTERN='[Aa]rmor'
readonly PIXEL_VENDOR_PATTERN='^[Gg]oogle$'
readonly PIXEL_MODEL_PATTERN='[Pp]ixel'

# Plausible size band for a ramdisk-carrying partition, in bytes. Used by
# mtk_sane_ramdisk_size to flag a dump that is obviously wrong - a truncated
# read, or a whole-disk grab where a partition was meant.
MTK_RAMDISK_MIN_BYTES=$((1024 * 1024))
MTK_RAMDISK_MAX_BYTES=$((128 * 1024 * 1024))
readonly MTK_RAMDISK_MIN_BYTES MTK_RAMDISK_MAX_BYTES

# ----------------------------------------------------------------------------
# Logging. Everything goes to stderr so stdout stays clean for captured data.
# ----------------------------------------------------------------------------

mtk_info() {
  printf '\033[0;34m[INFO]\033[0m  %s\n' "$*" >&2
}

mtk_warn() {
  printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2
}

mtk_error() {
  printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
}

mtk_fatal() {
  printf '\033[0;31m[FATAL]\033[0m %s\n' "$*" >&2
  exit 1
}

mtk_heading() {
  printf '\n\033[1;36m== %s ==\033[0m\n' "$*" >&2
}

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

# Artifacts live outside the repo: the pre-commit hook blocks every binary
# file, and a factory image is several GB. Only text manifests get committed.
mtk_cache_dir() {
  printf '%s' "${MTK_ROOT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mtk-root}"
}

mtk_stock_dir() {
  printf '%s/stock' "$(mtk_cache_dir)"
}

mtk_mtkclient_dir() {
  printf '%s/mtkclient' "$(mtk_cache_dir)"
}

mtk_venv_python() {
  printf '%s/venv/bin/python' "$(mtk_mtkclient_dir)"
}

# ----------------------------------------------------------------------------
# Device read seam
# ----------------------------------------------------------------------------

# Strip anything a property value has no business containing. adb shell also
# returns CRLF line endings, which silently break string comparisons.
mtk_sanitize() {
  printf '%s' "$1" | tr -d '\r' | tr -cd 'A-Za-z0-9 ._:/=+,-'
}

# dev_getprop <property-name>
# Prints the value, or nothing if unset. Never fails - an absent property and
# an empty one are the same thing to every caller here.
dev_getprop() {
  local prop="$1"
  local raw=""

  if [[ -n ${MTK_ROOT_FIXTURE:-} ]]; then
    # Fixture format is one `key=value` per line, matching `getprop` output
    # once the [brackets] are stripped.
    raw="$(grep -m1 -- "^${prop}=" "${MTK_ROOT_FIXTURE}/props.txt" 2>/dev/null || true)"
    raw="${raw#*=}"
  else
    raw="$(mtk_adb shell getprop "$prop" 2>/dev/null || true)"
  fi

  mtk_sanitize "$raw"
}

# dev_list_by_name
# Prints one partition name per line, unsorted, as the device reports them.
dev_list_by_name() {
  if [[ -n ${MTK_ROOT_FIXTURE:-} ]]; then
    tr -d '\r' <"${MTK_ROOT_FIXTURE}/by-name.txt" 2>/dev/null || true
    return 0
  fi

  mtk_adb shell 'ls -1 /dev/block/by-name/ 2>/dev/null' 2>/dev/null | tr -d '\r' || true
}

_MTK_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=mtk_device.sh
source "$_MTK_LIB_DIR/mtk_device.sh"
# shellcheck source=mtk_classify.sh
source "$_MTK_LIB_DIR/mtk_classify.sh"
# shellcheck source=mtk_partitions.sh
source "$_MTK_LIB_DIR/mtk_partitions.sh"
