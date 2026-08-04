#!/bin/bash

# ============================================================================
# 10-recon.sh - Read every fact needed to choose a rooting path. READ-ONLY.
#
# This script never writes to the device. It issues no reboot, no fastboot
# command, no `settings put`, and touches no partition. tests/run_tests.sh
# enforces that with a static scan of this file, because the phone it will
# most often be pointed at is a daily driver.
#
# Output: a facts file under the cache dir, plus a decision summary naming
# which of the four paths applies and what is still unknown.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# shellcheck source=../lib/mtk_common.sh
source "$SCRIPT_DIR/../lib/mtk_common.sh"

# Properties captured verbatim into the facts file. Grouped by what they tell
# us; all are read-only.
readonly -a FACT_PROPS=(
  ro.product.manufacturer
  ro.product.model
  ro.product.name
  ro.product.device
  ro.product.first_api_level
  ro.board.platform
  ro.hardware
  ro.build.fingerprint
  ro.build.id
  ro.build.version.release
  ro.build.version.sdk
  ro.build.version.security_patch
  ro.build.type
  ro.boot.slot_suffix
  ro.boot.flash.locked
  ro.boot.verifiedbootstate
  ro.boot.vbmeta.device_state
  ro.boot.veritymode
  ro.boot.hardware
  ro.boot.bootloader
  ro.bootloader
  ro.oem_unlock_supported
  sys.oem_unlock_allowed
  ro.carrier
  gsm.sim.operator.alpha
  ro.crypto.state
)

REQUESTED_SERIAL=""
EXPLAIN_ONLY=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--serial <serial>] [--explain-classification] [--help]

Reads device facts read-only and prints a path decision summary.
Writes a facts file to \$(mtk_cache_dir)/device-facts-<class>-<serial>-<ts>.txt

  --serial <serial>          Target a specific device (required if >1 attached)
  --explain-classification   Show why the device classified as it did, then exit
  --help                     This text

Environment:
  MTK_ROOT_FIXTURE=<dir>     Read from fixture files instead of a device (tests)
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Unlock / lock signal interpretation
# ---------------------------------------------------------------------------

# carrier_lock_verdict
#
# Deliberately hardcoded to UNDETERMINED. There is no read-only property that
# distinguishes "carrier-locked" from "the OEM unlocking toggle is simply off":
#   - sys.oem_unlock_allowed mirrors the toggle, so it reads empty/0 in both cases
#   - ro.oem_unlock_supported is not populated on Pixel devices at all
#   - settings get global oem_unlock_allowed is null until the toggle is used
# Printing a negative here would wrongly rule out a whole path, so the script
# reports the raw signals and refuses to draw the conclusion.
carrier_lock_verdict() {
  printf 'UNDETERMINED'
}

read_unlock_signals() {
  UNLOCK_FLASH_LOCKED="$(dev_getprop ro.boot.flash.locked)"
  UNLOCK_VBSTATE="$(dev_getprop ro.boot.verifiedbootstate)"
  UNLOCK_DEVICE_STATE="$(dev_getprop ro.boot.vbmeta.device_state)"
  UNLOCK_SYS_ALLOWED="$(dev_getprop sys.oem_unlock_allowed)"
  UNLOCK_OEM_SUPPORTED="$(dev_getprop ro.oem_unlock_supported)"

  UNLOCK_SETTING=""
  if [[ -z ${MTK_ROOT_FIXTURE:-} ]]; then
    UNLOCK_SETTING="$(mtk_adb shell settings get global oem_unlock_allowed 2>/dev/null | tr -d '\r' || true)"
  fi

  # The toggle's own state is the thing that matters for unlockability, and it
  # is precisely the thing that cannot be read reliably. Track it as tri-state.
  case "$UNLOCK_SYS_ALLOWED" in
    1) UNLOCK_TOGGLE="ON" ;;
    0) UNLOCK_TOGGLE="OFF" ;;
    *) UNLOCK_TOGGLE="UNREADABLE" ;;
  esac
}

# ---------------------------------------------------------------------------
# Facts file
# ---------------------------------------------------------------------------

write_facts_file() {
  local out_path="$1"
  local tmp_file="" prop="" value=""

  tmp_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmp_file now; it must survive this scope
  trap "rm -f '$tmp_file'" RETURN

  {
    printf '# mtk_root device facts\n'
    printf '# generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# serial: %s\n' "$MTK_SERIAL"
    printf '# class: %s\n' "$MTK_DEVICE_CLASS"
    printf '#\n'
    printf '# This file is read by 20-dump-stock.sh, and is the source for the\n'
    printf '# tests/fixtures/ entries. Format is deliberately line-oriented.\n'
    printf '\n[properties]\n'
    for prop in "${FACT_PROPS[@]}"; do
      value="$(dev_getprop "$prop")"
      printf '%s=%s\n' "$prop" "$value"
    done

    printf '\n[settings]\n'
    printf 'global.oem_unlock_allowed=%s\n' "${UNLOCK_SETTING:-}"

    printf '\n[partitions]\n'
    printf 'ab_scheme=%s\n' "$MTK_AB_SCHEME"
    printf 'slot_suffix=%s\n' "${MTK_SLOT_SUFFIX:-}"
    printf 'slot_suffix_assumed=%s\n' "${MTK_SLOT_ASSUMED:-0}"
    printf 'ramdisk_partition=%s\n' "${MTK_RAMDISK_PART:-}"
    printf 'ramdisk_carrier=%s\n' "$(mtk_ramdisk_carrier)"
    printf 'vbmeta_partition=%s\n' "${MTK_VBMETA_PART:-}"

    printf '\n[by-name]\n'
    printf '%s\n' "$MTK_BY_NAME"
  } >"$tmp_file"

  mv "$tmp_file" "$out_path"
  trap - RETURN
  printf '%s' "$out_path"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

report_partitions() {
  local carrier=""
  carrier="$(mtk_ramdisk_carrier)"

  mtk_heading "Partitions"
  printf '  A/B scheme      : %s\n' "$MTK_AB_SCHEME"
  if [[ ${MTK_SLOT_ASSUMED:-0} -eq 1 ]]; then
    printf '  slot suffix     : %s  (ASSUMED - ro.boot.slot_suffix was empty)\n' "${MTK_SLOT_SUFFIX:-none}"
  else
    printf '  slot suffix     : %s\n' "${MTK_SLOT_SUFFIX:-none}"
  fi
  printf '  ramdisk lives in: %s  -> partition %s\n' "${carrier:-UNKNOWN}" "${MTK_RAMDISK_PART:-NONE FOUND}"
  printf '  vbmeta          : %s\n' "${MTK_VBMETA_PART:-NONE FOUND}"

  # boot vs init_boot is the single most consequential fact here: patching the
  # wrong one produces a device that does not boot.
  if [[ $carrier == "init_boot" ]]; then
    printf '  => Magisk must patch INIT_BOOT on this device.\n'
  elif [[ $carrier == "boot" ]]; then
    printf '  => Magisk must patch BOOT on this device (no init_boot present).\n'
  else
    printf '  => Could not identify a ramdisk carrier. Do not flash anything.\n'
  fi

  mtk_check_layout_expectation || true
}

report_lock_state() {
  mtk_heading "Lock state"
  printf '  ro.boot.flash.locked        : %s\n' "${UNLOCK_FLASH_LOCKED:-<unset>}"
  printf '  ro.boot.verifiedbootstate   : %s\n' "${UNLOCK_VBSTATE:-<unset>}"
  printf '  ro.boot.vbmeta.device_state : %s\n' "${UNLOCK_DEVICE_STATE:-<unset>}"
  printf '  sys.oem_unlock_allowed      : %s\n' "${UNLOCK_SYS_ALLOWED:-<unset>}"
  printf '  ro.oem_unlock_supported     : %s\n' "${UNLOCK_OEM_SUPPORTED:-<unset>}"
  printf '  settings oem_unlock_allowed : %s\n' "${UNLOCK_SETTING:-<unset>}"
  printf '\n'
  printf '  OEM-unlock toggle : %s\n' "$UNLOCK_TOGGLE"
  printf '  Carrier lock      : %s\n' "$(carrier_lock_verdict)"
  printf '\n'
  printf '  Carrier lock cannot be determined from any property. An unset\n'
  printf '  sys.oem_unlock_allowed means the toggle is off, which is NOT the same\n'
  printf '  as carrier-locked. Settle it out of band: check the IMEI with the\n'
  printf '  carrier, or in the Google Store order record.\n'
}

report_manual_checks() {
  mtk_heading "Check these on the phone screen yourself"
  printf '  Settings > System > Developer options > "OEM unlocking":\n'
  printf '    - toggleable  => bootloader unlock is permitted by the firmware\n'
  printf '    - greyed out  => blocked (carrier policy, no network, or unsupported)\n'
  printf '  A property can say the toggle is off; only the UI shows whether it\n'
  printf '  CAN be turned on. That distinction decides the path.\n'
}

report_decision() {
  mtk_heading "Decision summary"

  # The companion document that defines paths A-D was not provided to the
  # session that wrote this script, so the mapping below is inferred. Say so
  # every run rather than let a plausible-looking verdict pass as authoritative.
  printf '  \033[0;33mPATH SEMANTICS ARE ASSUMED\033[0m - the companion doc defining A/B/C/D was\n'
  printf '  not available when this was written. Reconcile before acting.\n\n'

  case "$MTK_DEVICE_CLASS" in
    ULEFONE)
      if [[ $UNLOCK_TOGGLE == "ON" ]]; then
        printf '  => PATH A (Ulefone, OEM unlocking available)\n'
        printf '     Next: ./20-dump-stock.sh --serial %s\n' "$MTK_SERIAL"
        printf '     Then patch %s with Magisk and flash MANUALLY.\n' "${MTK_RAMDISK_PART:-<unknown>}"
      else
        printf '  => PATH A or B (Ulefone; toggle reads %s)\n' "$UNLOCK_TOGGLE"
        printf '     Confirm the toggle on-screen before choosing.\n'
        printf '     If greyed out => PATH B: fastboot unlock is blocked, leaving the\n'
        printf '     mtkclient/BROM route, which is the untested one. Dump first:\n'
        printf '     ./20-dump-stock.sh --serial %s\n' "$MTK_SERIAL"
      fi
      ;;
    PIXEL)
      printf '  => PATH C or D (Pixel) - INDETERMINATE\n'
      printf '     The toggle reads %s and carrier lock is UNDETERMINED, so C and D\n' "$UNLOCK_TOGGLE"
      printf '     cannot be told apart from properties alone.\n\n'
      printf '  \033[0;31mThis toolkit will not act on a Pixel.\033[0m It is the daily driver;\n'
      printf '  recon only. No dump, unlock, or flash step here targets it.\n'
      ;;
    *)
      printf '  => NO PATH. Device did not classify.\n'
      printf '     %s\n' "$MTK_CLASS_REASON"
      printf '     Refusing to guess. Run --explain-classification, and if this is\n'
      printf '     genuinely the Ulefone, widen the patterns at the top of\n'
      printf '     lib/mtk_common.sh.\n'
      ;;
  esac

  mtk_heading "Still unknown"
  printf '  - Whether the OEM unlocking toggle can be enabled (needs the screen)\n'
  printf '  - Carrier lock status (needs an out-of-band IMEI check)\n'
  if [[ $MTK_DEVICE_CLASS == "ULEFONE" ]]; then
    printf '  - Whether this unit BROM is open or SLA/DAA-locked (needs mtkclient)\n'
    printf '  - Whether fastboot flashing unlock is enabled in this firmware build\n'
  fi
}

main() {
  printf '\033[1m%s - read-only device recon\033[0m\n' "$SCRIPT_NAME"

  if ! mtk_select_device "$REQUESTED_SERIAL"; then
    exit 1
  fi

  # Before any getprop: an unauthorized device answers every property query
  # with an empty string, which is indistinguishable from "device has no such
  # property" and would produce a confidently wrong report.
  if ! mtk_require_authorized; then
    exit 1
  fi

  mtk_info "Target: ${MTK_SERIAL}"

  classify_device

  if [[ $EXPLAIN_ONLY -eq 1 ]]; then
    mtk_explain_classification
    exit 0
  fi

  mtk_heading "Identity"
  printf '  serial          : %s\n' "$MTK_SERIAL"
  printf '  manufacturer    : %s\n' "${MTK_PROP_MANUFACTURER:-<unset>}"
  printf '  model           : %s\n' "${MTK_PROP_MODEL:-<unset>}"
  printf '  platform        : %s / %s\n' "${MTK_PROP_PLATFORM:-<unset>}" "${MTK_PROP_HARDWARE:-<unset>}"
  printf '  classified as   : %s\n' "$MTK_DEVICE_CLASS"
  printf '  because         : %s\n' "$MTK_CLASS_REASON"

  if [[ $MTK_DEVICE_CLASS == "UNKNOWN" ]]; then
    mtk_error "Device did not match any known profile - refusing to report a path."
    report_decision
    exit 1
  fi

  if ! discover_partitions; then
    mtk_error "Could not read /dev/block/by-name/ - no partition facts available."
    mtk_error "On most devices that listing needs no root; if it is empty, the"
    mtk_error "device may be in an unusual state. Do not flash anything."
    exit 1
  fi

  read_unlock_signals

  report_partitions
  report_lock_state
  report_manual_checks

  local cache_dir="" facts_path=""
  cache_dir="$(mtk_cache_dir)"
  mkdir -p "$cache_dir"
  facts_path="${cache_dir}/device-facts-${MTK_DEVICE_CLASS}-${MTK_SERIAL}-$(date -u '+%Y%m%dT%H%M%SZ').txt"
  write_facts_file "$facts_path" >/dev/null

  report_decision

  mtk_heading "Facts file"
  printf '  %s\n' "$facts_path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      [[ $# -ge 2 ]] || {
        mtk_error "--serial needs a value"
        exit 1
      }
      REQUESTED_SERIAL="$2"
      shift 2
      ;;
    --explain-classification)
      EXPLAIN_ONLY=1
      shift
      ;;
    -h | --help) usage ;;
    *)
      mtk_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

main
