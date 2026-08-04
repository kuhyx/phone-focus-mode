#!/bin/bash

# ============================================================================
# 90-verify-root.sh - Post-flash checks, reported one by one.
#
# There is deliberately NO aggregate "success" verdict. Root can be partially
# working in ways that matter: su present but Magisk's daemon absent, or the
# ramdisk flashed while vbmeta verification still rejects it. A single
# pass/fail hides exactly the case worth knowing about.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# shellcheck source=../lib/mtk_common.sh
source "$SCRIPT_DIR/../lib/mtk_common.sh"

# Known-current Magisk at the time of writing. Checked so a stale APK is
# noticed; a mismatch is informational, not a failure.
readonly MAGISK_KNOWN_VERSION="30.7"

REQUESTED_SERIAL=""

PASS=0
FAIL=0
INFO=0

check_pass() {
  PASS=$((PASS + 1))
  printf '  \033[0;32m[PASS]\033[0m %-28s %s\n' "$1" "${2:-}"
}

check_fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[0;31m[FAIL]\033[0m %-28s %s\n' "$1" "${2:-}"
}

check_info() {
  INFO=$((INFO + 1))
  printf '  \033[0;34m[INFO]\033[0m %-28s %s\n' "$1" "${2:-}"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--serial <serial>] [--help]

Runs post-flash root checks and reports each independently.
Read-only: queries the device, changes nothing.
EOF
  exit 0
}

check_su() {
  local result=""
  result="$(mtk_adb shell 'su -c id' 2>/dev/null | tr -d '\r' || true)"

  if [[ $result == *"uid=0"* ]]; then
    check_pass "su grants uid=0" "$result"
    return 0
  fi

  # An unanswered Superuser prompt looks identical to no root at all.
  check_fail "su grants uid=0" "got: ${result:-<no output>}"
  printf '         If a Superuser prompt is waiting on the phone, grant it and re-run.\n'
  return 1
}

check_magisk() {
  local version="" version_code=""
  version="$(mtk_adb shell 'su -c "magisk -c"' 2>/dev/null | tr -d '\r' || true)"
  version_code="$(mtk_adb shell 'su -c "magisk -V"' 2>/dev/null | tr -d '\r' || true)"

  if [[ -z $version && -z $version_code ]]; then
    check_fail "magisk binary responds" "no output from 'magisk -c'"
    return 1
  fi
  check_pass "magisk binary responds" "${version} (code ${version_code})"

  if [[ $version == *"$MAGISK_KNOWN_VERSION"* ]]; then
    check_info "magisk version" "matches expected v${MAGISK_KNOWN_VERSION}"
  else
    check_info "magisk version" "device has '${version}', toolkit expected v${MAGISK_KNOWN_VERSION}"
  fi
  return 0
}

check_daemon() {
  local result=""
  result="$(mtk_adb shell 'su -c "magisk --ping"' 2>/dev/null | tr -d '\r' || true)"

  if [[ $result == "Pong" || $result == "pong" ]]; then
    check_pass "magisk daemon running" "$result"
    return 0
  fi
  check_fail "magisk daemon running" "ping returned: ${result:-<nothing>}"
  return 1
}

check_boot_state() {
  local vbstate="" locked=""
  vbstate="$(dev_getprop ro.boot.verifiedbootstate)"
  locked="$(dev_getprop ro.boot.flash.locked)"

  # After unlocking, verified boot should no longer report green. Still-green
  # alongside a claim of successful flashing means the flash did not take.
  case "$vbstate" in
    orange | yellow)
      check_pass "verified boot state" "${vbstate} (expected after unlock)"
      ;;
    green)
      check_fail "verified boot state" "green - bootloader still locked, flash did not take"
      ;;
    *)
      check_info "verified boot state" "${vbstate:-<unset>}"
      ;;
  esac

  if [[ $locked == "0" ]]; then
    check_pass "bootloader unlocked" "ro.boot.flash.locked=0"
  elif [[ $locked == "1" ]]; then
    check_fail "bootloader unlocked" "ro.boot.flash.locked=1 - still locked"
  else
    check_info "bootloader unlocked" "ro.boot.flash.locked=${locked:-<unset>}"
  fi
}

check_ramdisk_changed() {
  local manifest="" carrier=""
  manifest="$(mtk_stock_dir)/${MTK_SERIAL}/manifest.txt"

  if [[ ! -f $manifest ]]; then
    check_info "stock manifest" "none at ${manifest} - cannot compare against stock"
    return 0
  fi

  carrier="$(grep -m1 '^ramdisk_carrier=' "$manifest" 2>/dev/null || true)"
  check_info "stock manifest" "present (${carrier#*=}) - compare hashes manually before relocking"
}

main() {
  printf '\033[1m%s - post-flash verification\033[0m\n' "$SCRIPT_NAME"

  if ! mtk_select_device "$REQUESTED_SERIAL"; then
    exit 1
  fi
  if ! mtk_require_authorized; then
    exit 1
  fi

  classify_device
  mtk_info "Target: ${MTK_SERIAL} (${MTK_DEVICE_CLASS})"

  mtk_heading "Checks"
  # Each runs regardless of earlier failures - a partial result is the point.
  check_su || true
  check_magisk || true
  check_daemon || true
  check_boot_state
  check_ramdisk_changed

  mtk_heading "Result"
  printf '  %d passed, %d failed, %d informational\n\n' "$PASS" "$FAIL" "$INFO"
  printf '  Read the checks individually. There is no combined verdict here on\n'
  printf '  purpose: partial root is a real state and it matters which part failed.\n\n'
  printf '  Play Integrity / SafetyNet is deliberately NOT checked - it needs\n'
  printf '  Zygisk plus a hiding config, and is a separate exercise.\n'

  [[ $FAIL -eq 0 ]]
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
    -h | --help) usage ;;
    *)
      mtk_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

main
