#!/bin/bash
# Partition discovery, ramdisk carrier and layout expectations.
#
# Sourced by mtk_common.sh, which stays the single entry point the
# mtk_root scripts source, so their public surface is unchanged.

# ----------------------------------------------------------------------------
# Partition discovery
# ----------------------------------------------------------------------------

# discover_partitions
# Sets MTK_AB_SCHEME, MTK_SLOT_SUFFIX, MTK_RAMDISK_PART, MTK_VBMETA_PART,
# MTK_BY_NAME (newline-separated listing).
#
# The governing rule: never name a partition in a conditional that was not
# first observed in the listing. The AOSP rule (devices launching on Android
# 13+ carry the ramdisk in init_boot; earlier ones keep it in boot) explains
# WHY the preference order below is correct, but the code never consults the
# API level to decide - it reads the filesystem. That is what lets one code
# path serve both a Pixel (no init_boot -> falls through to boot) and a
# 13-launch MediaTek device (init_boot present -> taken) without branching on
# device identity.
discover_partitions() {
  local entries="" suffix="" candidate="" name=""

  entries="$(dev_list_by_name)"
  MTK_BY_NAME="$entries"
  export MTK_BY_NAME

  if [[ -z $entries ]]; then
    MTK_AB_SCHEME="unknown"
    MTK_SLOT_SUFFIX=""
    MTK_RAMDISK_PART=""
    MTK_VBMETA_PART=""
    export MTK_AB_SCHEME MTK_SLOT_SUFFIX MTK_RAMDISK_PART MTK_VBMETA_PART
    return 1
  fi

  # Slot scheme comes from observed suffixes, not from a product table.
  if grep -qE '_a$' <<<"$entries"; then
    MTK_AB_SCHEME="A/B"
  else
    MTK_AB_SCHEME="A-only"
  fi

  # Prefer the device's own view of the active slot; fall back to _a only
  # because a dump has to start somewhere, and say so in the report.
  suffix="$(dev_getprop ro.boot.slot_suffix)"
  if [[ -z $suffix && $MTK_AB_SCHEME == "A/B" ]]; then
    suffix="_a"
    MTK_SLOT_ASSUMED=1
  else
    MTK_SLOT_ASSUMED=0
  fi
  MTK_SLOT_SUFFIX="$suffix"

  # init_boot first: its presence is decisive. A device that has it keeps the
  # ramdisk there even though boot also exists, so checking boot first would
  # pick the wrong partition on exactly the hardware this toolkit is for.
  MTK_RAMDISK_PART=""
  for candidate in init_boot boot; do
    for name in "${candidate}${suffix}" "${candidate}"; do
      if grep -qxF -- "$name" <<<"$entries"; then
        MTK_RAMDISK_PART="$name"
        break 2
      fi
    done
  done

  MTK_VBMETA_PART=""
  for name in "vbmeta${suffix}" "vbmeta"; do
    if grep -qxF -- "$name" <<<"$entries"; then
      MTK_VBMETA_PART="$name"
      break
    fi
  done

  export MTK_AB_SCHEME MTK_SLOT_SUFFIX MTK_RAMDISK_PART MTK_VBMETA_PART MTK_SLOT_ASSUMED

  [[ -n $MTK_RAMDISK_PART ]]
}

# mtk_ramdisk_carrier - "init_boot" or "boot", suffix stripped.
mtk_ramdisk_carrier() {
  local part="${MTK_RAMDISK_PART:-}"
  printf '%s' "${part%_[ab]}"
}

# mtk_check_layout_expectation
# Cross-check only. first_api_level >= 33 predicts init_boot; below predicts
# boot. A mismatch means either a vendor deviation or a bad read - the human
# should look, but the filesystem still wins.
mtk_check_layout_expectation() {
  local api_level="" carrier="" expected=""

  api_level="$(dev_getprop ro.product.first_api_level)"
  carrier="$(mtk_ramdisk_carrier)"

  [[ -z $api_level || -z $carrier ]] && return 0
  [[ $api_level =~ ^[0-9]+$ ]] || return 0

  if [[ $api_level -ge 33 ]]; then
    expected="init_boot"
  else
    expected="boot"
  fi

  if [[ $carrier != "$expected" ]]; then
    mtk_warn "Layout disagrees with expectation: first_api_level=${api_level} predicts '${expected}', device shows '${carrier}'."
    mtk_warn "Trusting the device. Verify before flashing anything."
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Host environment checks (read-only; install.sh owns the mutating half)
# ----------------------------------------------------------------------------

# mtk_udev_catchall_files
# Prints any rules file containing an ACTIVE wildcard-vendor rule granting
# world read/write. Such a rule applies to every USB device on the system -
# storage, security keys, everything - not just phones.
#
# Commented-out lines are ignored: --fix-udev disables a rule by commenting it
# rather than deleting it, so matching those would leave the check permanently
# red after it had already been dealt with. Only *.rules files are considered,
# since udev itself skips any other suffix (including our .bak- backups).
mtk_udev_catchall_files() {
  local file=""
  for file in /etc/udev/rules.d/*.rules; do
    [[ -f $file ]] || continue
    if grep -qE '^[^#]*idVendor\}=="\*"[^#]*MODE="0666"|^[^#]*MODE="0666"[^#]*idVendor\}=="\*"' \
      "$file" 2>/dev/null; then
      printf '%s\n' "$file"
    fi
  done
}

# mtk_check_venv - is the mtkclient venv actually usable?
# Checks importability, not directory existence: the venv found on this host
# in Aug 2026 existed, looked complete, and failed at `import usb` because a
# Python upgrade had orphaned it.
mtk_check_venv() {
  local python_bin=""
  python_bin="$(mtk_venv_python)"

  if [[ ! -x $python_bin ]]; then
    printf 'missing: no interpreter at %s' "$python_bin"
    return 1
  fi

  if ! "$python_bin" -c 'import usb, usb.core, serial' 2>/dev/null; then
    local err=""
    err="$("$python_bin" -c 'import usb, usb.core, serial' 2>&1 | tail -1)"
    printf 'broken: %s' "$err"
    return 1
  fi

  printf 'ok: %s' "$("$python_bin" --version 2>&1)"
  return 0
}

# mtk_sha256 <file>
mtk_sha256() {
  sha256sum "$1" | awk '{ print $1 }'
}

# mtk_file_size <file>
mtk_file_size() {
  stat -c '%s' "$1"
}

# mtk_sane_ramdisk_size <bytes>
# A dump outside this band is not necessarily wrong, but it is worth stopping
# for: an empty or truncated read and an accidental whole-disk grab both look
# like success to mtkclient's exit code.
mtk_sane_ramdisk_size() {
  local size="$1"

  if [[ ! $size =~ ^[0-9]+$ ]]; then
    printf 'size is not a number: %s' "$size"
    return 1
  fi
  if [[ $size -lt $MTK_RAMDISK_MIN_BYTES ]]; then
    printf 'implausibly small: %s bytes (< %s)' "$size" "$MTK_RAMDISK_MIN_BYTES"
    return 1
  fi
  if [[ $size -gt $MTK_RAMDISK_MAX_BYTES ]]; then
    printf 'implausibly large: %s bytes (> %s)' "$size" "$MTK_RAMDISK_MAX_BYTES"
    return 1
  fi
  printf '%s bytes' "$size"
  return 0
}
