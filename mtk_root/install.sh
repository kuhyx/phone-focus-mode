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

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
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

install_udev() {
  mtk_heading "udev rules"

  if [[ ! -f $UDEV_SOURCE ]]; then
    mtk_error "Missing rules source: ${UDEV_SOURCE}"
    return 1
  fi

  if [[ -f $UDEV_TARGET ]] && sudo cmp -s "$UDEV_SOURCE" "$UDEV_TARGET"; then
    mtk_info "Rules already current at ${UDEV_TARGET}"
  else
    mtk_info "Installing ${UDEV_TARGET}"
    sudo install -m 0644 "$UDEV_SOURCE" "$UDEV_TARGET"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
  fi

  if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
    if udevadm verify "$UDEV_TARGET" >/dev/null 2>&1; then
      mtk_info "udevadm verify: clean"
    else
      mtk_error "udevadm verify rejected ${UDEV_TARGET}"
      return 1
    fi
  fi

  handle_catchall
}

handle_catchall() {
  local catchall=""
  catchall="$(mtk_udev_catchall_files)"
  [[ -z $catchall ]] && return 0

  mtk_warn "World-writable catch-all udev rule found in:"
  printf '%s\n' "$catchall" | sed 's/^/    /'
  mtk_warn 'A rule matching idVendor=="*" with MODE="0666" grants every local'
  mtk_warn 'process read/write access to EVERY USB device, not just phones.'

  if [[ $FIX_UDEV -eq 0 ]]; then
    mtk_warn "Not changing it. Another script may depend on it."
    mtk_warn "To narrow it: ${SCRIPT_NAME} --fix-udev"
    return 0
  fi

  local file="" stamp=""
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    mtk_info "Backing up ${file} -> ${file}.bak-${stamp}"
    sudo cp -a "$file" "${file}.bak-${stamp}"
    # Comment the offending line rather than deleting it, so the change is
    # obvious and trivially reversible.
    sudo sed -i -E 's|^([^#].*idVendor\}=="\*".*MODE="0666".*)$|# disabled by mtk_root install.sh --fix-udev: world-writable catch-all\n#\1|' "$file"
    mtk_info "Commented catch-all in ${file}"
  done <<<"$catchall"

  sudo udevadm control --reload-rules
  sudo udevadm trigger
}

setup_mtkclient() {
  mtk_heading "mtkclient"

  local clone_dir="" python_bin=""
  clone_dir="$(mtk_mtkclient_dir)"

  if [[ -d "$clone_dir/.git" ]]; then
    mtk_info "Updating existing clone at ${clone_dir}"
    git -C "$clone_dir" pull --ff-only || mtk_warn "Pull failed; continuing with current checkout."
  else
    mtk_info "Cloning ${MTKCLIENT_REPO}"
    mkdir -p "$(dirname "$clone_dir")"
    git clone --depth 1 "$MTKCLIENT_REPO" "$clone_dir"
  fi

  local rev=""
  rev="$(git -C "$clone_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  mtk_info "mtkclient at rev ${rev}"

  # Rebuild the venv when it cannot import its dependencies. A Python upgrade
  # orphans a venv while leaving it looking complete on disk - the venv found
  # on this host in Aug 2026 failed exactly that way.
  python_bin="$(mtk_venv_python)"
  if ! mtk_check_venv >/dev/null 2>&1; then
    if [[ -d "$clone_dir/venv" ]]; then
      mtk_warn "Existing venv is unusable; rebuilding."
      rm -rf "$clone_dir/venv"
    fi
    mtk_info "Creating venv with $(python3 -V 2>&1)"
    python3 -m venv "$clone_dir/venv"
    "$clone_dir/venv/bin/pip" install --upgrade pip

    if [[ -f "$clone_dir/requirements.txt" ]]; then
      "$clone_dir/venv/bin/pip" install -r "$clone_dir/requirements.txt"
    else
      # Newer mtkclient revisions ship a pyproject instead of requirements.txt.
      mtk_info "No requirements.txt; installing the package itself."
      "$clone_dir/venv/bin/pip" install "$clone_dir"
    fi
  else
    mtk_info "venv already usable."
  fi

  local status=""
  if status="$(mtk_check_venv)"; then
    mtk_info "venv check: ${status}"
  else
    mtk_error "venv still unusable after install: ${status}"
    mtk_error "Read ${clone_dir}/README.md - its install steps may have changed."
    return 1
  fi
}

prepare_cache() {
  mtk_heading "Workspace"
  local cache_dir=""
  cache_dir="$(mtk_cache_dir)"
  mkdir -p "$cache_dir" "$(mtk_stock_dir)"
  mtk_info "Cache: ${cache_dir}"
  mtk_info "Artifacts stay here, outside the repo - it rejects binaries, and"
  mtk_info "factory images run to several GB."
}

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
