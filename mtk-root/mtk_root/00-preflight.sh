#!/bin/bash

# ============================================================================
# 00-preflight.sh - Verify the host toolkit is intact. No device required.
#
# Run this first on the day the phone arrives, to confirm nothing rotted while
# it was in transit. Every check reports independently; the script exits
# non-zero if any FAIL, so it is usable as a gate.
#
# This checks the HOST only. It cannot confirm that udev actually grants
# access to a MediaTek device in BROM mode - that needs the hardware.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# shellcheck source=../lib/mtk_common.sh
source "$SCRIPT_DIR/../lib/mtk_common.sh"

readonly UDEV_RULES_FILE="/etc/udev/rules.d/60-mtk-root.rules"

PASS=0
FAIL=0
WARN=0

pass() {
  PASS=$((PASS + 1))
  printf '  \033[0;32m[PASS]\033[0m %-34s %s\n' "$1" "${2:-}"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[0;31m[FAIL]\033[0m %-34s %s\n' "$1" "${2:-}"
}

warn() {
  WARN=$((WARN + 1))
  printf '  \033[0;33m[WARN]\033[0m %-34s %s\n' "$1" "${2:-}"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--help]

Verifies host tooling for the mtk_root toolkit. No device needed.
Exits non-zero if any check fails.
EOF
  exit 0
}

check_tools() {
  mtk_heading "Tools"

  local -a required=(adb fastboot python3 git sha256sum)
  local tool="" version=""

  for tool in "${required[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "$tool" "not installed - run install.sh"
      continue
    fi
    # Invoke it, don't just locate it: a binary on PATH that cannot run is a
    # failure mode `command -v` reports as success.
    #
    # Each capture is wrapped in `|| true` and reads the whole stream before
    # slicing. Piping straight into `head -1` closes the pipe early, and under
    # `set -o pipefail` the resulting SIGPIPE kills this script outright.
    version=""
    case "$tool" in
      adb) version="$(adb version 2>/dev/null || true)" ;;
      fastboot) version="$(fastboot --version 2>/dev/null || true)" ;;
      python3) version="$(python3 -V 2>&1 || true)" ;;
      git) version="$(git --version 2>/dev/null || true)" ;;
      *) version="$("$tool" --version 2>/dev/null || true)" ;;
    esac
    version="${version%%$'\n'*}"
    if [[ -z $version ]]; then
      fail "$tool" "present but did not respond to a version query"
    else
      pass "$tool" "$version"
    fi
  done
}

check_groups() {
  mtk_heading "Group membership"

  local -a wanted=(plugdev adbusers)
  local group="" active_groups=""
  active_groups=" $(id -nG) "

  for group in "${wanted[@]}"; do
    if ! getent group "$group" >/dev/null 2>&1; then
      warn "$group" "group does not exist on this system"
      continue
    fi
    if [[ $active_groups == *" $group "* ]]; then
      pass "$group" "active in this session"
    elif id -nG "$USER" 2>/dev/null | grep -qw "$group"; then
      # Membership that the current login session predates. The rule is real
      # but will not take effect until re-login, and USB access will fail in
      # a way that looks like a udev problem.
      warn "$group" "member, but not in this session - log out and back in"
    else
      fail "$group" "not a member - run install.sh"
    fi
  done
}

check_udev() {
  mtk_heading "udev rules"

  if [[ -f $UDEV_RULES_FILE ]]; then
    if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
      # A real syntax verdict. `udevadm control --reload` exits 0 regardless,
      # so it cannot be used to validate anything.
      if udevadm verify "$UDEV_RULES_FILE" >/dev/null 2>&1; then
        pass "60-mtk-root.rules" "present, udevadm verify clean"
      else
        fail "60-mtk-root.rules" "present but udevadm verify REJECTED it"
      fi
    else
      warn "60-mtk-root.rules" "present; udevadm verify unavailable, syntax unchecked"
    fi
  else
    fail "60-mtk-root.rules" "missing - run install.sh"
  fi

  # A wildcard-vendor world-writable rule is a genuine finding, not a nit: it
  # applies to every USB device attached to this machine, not just phones.
  local catchall=""
  catchall="$(mtk_udev_catchall_files)"
  if [[ -n $catchall ]]; then
    fail "no world-writable catch-all" "found in: $(tr '\n' ' ' <<<"$catchall")"
    printf '         A rule matching idVendor=="*" with MODE="0666" grants every\n'
    printf '         local process read/write access to EVERY USB device, including\n'
    printf '         storage and security keys. Narrow it: install.sh --fix-udev\n'
  else
    pass "no world-writable catch-all" "no wildcard 0666 rule found"
  fi
}

check_venv() {
  mtk_heading "mtkclient"

  local venv_status=""
  if venv_status="$(mtk_check_venv)"; then
    pass "venv importable" "$venv_status"
  else
    fail "venv importable" "$venv_status"
    printf '         The venv existing is not enough - it must be able to import\n'
    printf '         usb/serial. A Python upgrade orphans a venv while leaving it\n'
    printf '         looking complete. Rebuild: install.sh\n'
  fi

  local clone_dir=""
  clone_dir="$(mtk_mtkclient_dir)"
  if [[ -d "$clone_dir/.git" ]]; then
    local rev=""
    rev="$(git -C "$clone_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    pass "mtkclient checkout" "rev ${rev}"
  else
    fail "mtkclient checkout" "not a git clone at ${clone_dir} - run install.sh"
  fi
}

check_cache() {
  mtk_heading "Workspace"

  local cache_dir=""
  cache_dir="$(mtk_cache_dir)"

  if [[ ! -d $cache_dir ]]; then
    fail "cache dir" "missing: ${cache_dir} - run install.sh"
    return
  fi
  if [[ -w $cache_dir ]]; then
    pass "cache dir writable" "$cache_dir"
  else
    fail "cache dir writable" "not writable: ${cache_dir}"
  fi
}

main() {
  printf '\033[1m%s - host readiness for the mtk_root toolkit\033[0m\n' "$SCRIPT_NAME"

  check_tools
  check_groups
  check_udev
  check_venv
  check_cache

  mtk_heading "Result"
  printf '  %d passed, %d failed, %d warnings\n\n' "$PASS" "$FAIL" "$WARN"

  if [[ $FAIL -gt 0 ]]; then
    printf '\033[0;31mNOT READY\033[0m - resolve the failures above (usually: ./install.sh)\n'
    return 1
  fi
  if [[ $WARN -gt 0 ]]; then
    printf '\033[0;33mREADY, with warnings\033[0m - read them before trusting a USB connection.\n'
    return 0
  fi
  printf '\033[0;32mHOST READY\033[0m - udev access to a real MediaTek device remains unverified\n'
  printf 'until hardware is attached; that cannot be checked without the phone.\n'
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage ;;
    *)
      mtk_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

main
