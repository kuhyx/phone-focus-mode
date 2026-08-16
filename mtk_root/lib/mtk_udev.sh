#!/bin/bash
# udev rules and the mtkclient checkout for MediaTek rooting.
#
# Sourced by install.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and
# the helper functions and variables defined above the source line.

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

  local clone_dir=""
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
