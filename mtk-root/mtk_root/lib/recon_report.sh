#!/bin/bash
# Partition, lock-state and manual-check reporting for MTK recon.
#
# Sourced by 10-recon.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and
# the helper functions and variables defined above the source line.

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
