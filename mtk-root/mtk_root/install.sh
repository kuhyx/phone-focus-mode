#!/bin/bash

# ============================================================================
# install.sh - Set up host tooling for the mtk_root toolkit.
#
# Idempotent: safe to run repeatedly. Ends by running 00-preflight.sh, because
# a tool that was never executed is not installed, only copied.
#
# Leaves the older ~/.cache/bl9000-root workspace completely alone - a
# different script still owns it.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# shellcheck source=../lib/mtk_common.sh
source "$SCRIPT_DIR/../lib/mtk_common.sh"

readonly MTKCLIENT_REPO="https://github.com/bkerler/mtkclient"
readonly UDEV_SOURCE="$SCRIPT_DIR/udev/60-mtk-root.rules"
readonly UDEV_TARGET="/etc/udev/rules.d/60-mtk-root.rules"
readonly -a PACMAN_PACKAGES=(android-tools android-udev git python libusb)

FIX_UDEV=0
SKIP_PACMAN=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--fix-udev] [--skip-pacman] [--help]

Installs host dependencies, clones mtkclient into the cache dir, builds its
venv, and installs narrowed udev rules.

  --fix-udev     Also comment out any world-writable catch-all udev rule
                 (idVendor=="*" with MODE="0666"), keeping a timestamped
                 backup. Not done by default: another script may rely on it.
  --skip-pacman  Do not install system packages (useful when already present)
  --help         This text
EOF
  exit 0
}

install_packages() {
  mtk_heading "System packages"

  if [[ $SKIP_PACMAN -eq 1 ]]; then
    mtk_info "Skipping package installation (--skip-pacman)."
    return 0
  fi

  local -a missing=()
  local pkg=""
  for pkg in "${PACMAN_PACKAGES[@]}"; do
    if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    mtk_info "All required packages already installed."
    return 0
  fi

  mtk_info "Installing: ${missing[*]}"
  # Interactive by design. A non-interactive sudo pacman can block forever on
  # the database lock with no visible prompt; better to let it ask.
  if ! sudo pacman -S --needed "${missing[@]}"; then
    mtk_error "Package installation failed. Install manually: ${missing[*]}"
    return 1
  fi
  return 0
}

ensure_groups() {
  mtk_heading "Groups"

  local group="" changed=0
  for group in plugdev adbusers; do
    if ! getent group "$group" >/dev/null 2>&1; then
      mtk_info "Creating group ${group}"
      sudo groupadd "$group" || {
        mtk_warn "Could not create ${group}"
        continue
      }
    fi
    if id -nG "$USER" | grep -qw "$group"; then
      mtk_info "Already a member of ${group}"
    else
      mtk_info "Adding ${USER} to ${group}"
      sudo usermod -aG "$group" "$USER" && changed=1
    fi
  done

  if [[ $changed -eq 1 ]]; then
    mtk_warn "Group membership changed - log out and back in before USB access works."
  fi
}

# shellcheck source=lib/mtk_udev.sh
source "$SCRIPT_DIR/lib/mtk_udev.sh"

main() {
  printf '\033[1m%s - host setup for the mtk_root toolkit\033[0m\n' "$SCRIPT_NAME"

  install_packages
  ensure_groups
  prepare_cache
  install_udev
  setup_mtkclient

  mtk_heading "Verifying"
  if "$SCRIPT_DIR/00-preflight.sh"; then
    mtk_info "Install complete."
  else
    mtk_warn "Preflight reported problems - see above."
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-udev)
      FIX_UDEV=1
      shift
      ;;
    --skip-pacman)
      SKIP_PACMAN=1
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
