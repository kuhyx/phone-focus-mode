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

# mtk_adb <args...> - serial-pinned adb, so a second phone plugged in midway
# cannot silently become the target.
mtk_adb() {
  adb -s "${MTK_SERIAL:?mtk_select_device must run first}" "$@"
}

# ----------------------------------------------------------------------------
# Device presence and authorization
# ----------------------------------------------------------------------------

# mtk_list_devices - prints "<serial> <state>" per attached device.
mtk_list_devices() {
  adb devices 2>/dev/null |
    awk 'NR > 1 && $2 ~ /^(device|offline|unauthorized|recovery|sideload)$/ { print $1, $2 }'
}

# mtk_device_state <serial> - device|unauthorized|offline|absent
mtk_device_state() {
  local serial="$1"
  local state=""

  state="$(mtk_list_devices | awk -v s="$serial" '$1 == s { print $2; exit }')"
  printf '%s' "${state:-absent}"
}

# mtk_select_device [requested-serial]
# Sets MTK_SERIAL. Refuses when the choice is ambiguous rather than picking
# one - a wrong guess here targets the wrong phone.
mtk_select_device() {
  local requested="${1:-${MTK_SERIAL:-}}"
  local -a device_rows=()
  local -a serials=()
  local row=""

  if [[ -n ${MTK_ROOT_FIXTURE:-} ]]; then
    MTK_SERIAL="${MTK_SERIAL:-fixture}"
    export MTK_SERIAL
    return 0
  fi

  mapfile -t device_rows < <(mtk_list_devices)

  if [[ ${#device_rows[@]} -eq 0 ]]; then
    mtk_error "No device visible to adb."
    mtk_error "Check: cable seated, USB debugging enabled, and try 'adb devices'."
    return 1
  fi

  for row in "${device_rows[@]}"; do
    serials+=("${row%% *}")
  done

  if [[ -n $requested ]]; then
    for row in "${serials[@]}"; do
      if [[ $row == "$requested" ]]; then
        MTK_SERIAL="$requested"
        export MTK_SERIAL
        return 0
      fi
    done
    mtk_error "Requested serial '${requested}' is not attached. Attached: ${serials[*]}"
    return 1
  fi

  if [[ ${#serials[@]} -gt 1 ]]; then
    mtk_error "Multiple devices attached (${serials[*]}); refusing to guess."
    mtk_error "Re-run with --serial <serial>."
    return 1
  fi

  MTK_SERIAL="${serials[0]}"
  export MTK_SERIAL
  return 0
}

# mtk_require_authorized
# An unauthorized device answers every getprop with an empty string, which
# reads exactly like "this device has no properties". Catch it up front so the
# report never blames the device for a prompt sitting unanswered on its screen.
mtk_require_authorized() {
  local state=""

  [[ -n ${MTK_ROOT_FIXTURE:-} ]] && return 0

  state="$(mtk_device_state "${MTK_SERIAL}")"
  case "$state" in
    device)
      return 0
      ;;
    unauthorized)
      mtk_error "Device ${MTK_SERIAL} is UNAUTHORIZED."
      mtk_error "The RSA authorization prompt is on the phone's screen - unlock it and tap Allow."
      mtk_error "If no prompt appears: revoke USB debugging authorizations on the phone, then replug."
      return 1
      ;;
    offline)
      mtk_error "Device ${MTK_SERIAL} is OFFLINE. Replug the cable, or run 'adb kill-server'."
      return 1
      ;;
    *)
      mtk_error "Device ${MTK_SERIAL} is in state '${state}', which this toolkit does not read."
      return 1
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Classification
# ----------------------------------------------------------------------------

# classify_device
# Sets MTK_DEVICE_CLASS to ULEFONE, PIXEL or UNKNOWN, and MTK_CLASS_REASON to
# a human-readable explanation of how it got there.
#
# ULEFONE requires a positive MediaTek signal AND a vendor/model match - both,
# never either, and never "not a Pixel, so presumably the Ulefone". A third
# phone attached by accident must land in UNKNOWN.
classify_device() {
  local manufacturer="" model="" platform="" hardware="" device=""
  local mtk_match=0 ulefone_match=0 pixel_match=0

  manufacturer="$(dev_getprop ro.product.manufacturer)"
  model="$(dev_getprop ro.product.model)"
  platform="$(dev_getprop ro.board.platform)"
  hardware="$(dev_getprop ro.hardware)"
  device="$(dev_getprop ro.product.device)"

  MTK_PROP_MANUFACTURER="$manufacturer"
  MTK_PROP_MODEL="$model"
  MTK_PROP_PLATFORM="$platform"
  MTK_PROP_HARDWARE="$hardware"
  MTK_PROP_DEVICE="$device"

  if [[ $platform =~ $MTK_PLATFORM_PATTERN ]] || [[ $hardware =~ $MTK_PLATFORM_PATTERN ]]; then
    mtk_match=1
  fi
  if [[ $manufacturer =~ $ULEFONE_VENDOR_PATTERN ]] || [[ $model =~ $ULEFONE_MODEL_PATTERN ]]; then
    ulefone_match=1
  fi
  if [[ $manufacturer =~ $PIXEL_VENDOR_PATTERN ]] && [[ $model =~ $PIXEL_MODEL_PATTERN ]]; then
    pixel_match=1
  fi

  if [[ $mtk_match -eq 1 && $ulefone_match -eq 1 ]]; then
    MTK_DEVICE_CLASS="ULEFONE"
    MTK_CLASS_REASON="MediaTek platform [${platform:-unset}/${hardware:-unset}] and Ulefone identity [${manufacturer} ${model}]"
  elif [[ $pixel_match -eq 1 ]]; then
    MTK_DEVICE_CLASS="PIXEL"
    MTK_CLASS_REASON="Google Pixel identity [${manufacturer} ${model}]"
  else
    MTK_DEVICE_CLASS="UNKNOWN"
    MTK_CLASS_REASON="no rule matched: manufacturer=[${manufacturer}] model=[${model}] platform=[${platform}] hardware=[${hardware}]"
  fi

  export MTK_DEVICE_CLASS MTK_CLASS_REASON
  export MTK_PROP_MANUFACTURER MTK_PROP_MODEL MTK_PROP_PLATFORM MTK_PROP_HARDWARE MTK_PROP_DEVICE
}

# mtk_explain_classification - why classify_device decided what it did.
mtk_explain_classification() {
  printf 'ro.product.manufacturer = %s\n' "${MTK_PROP_MANUFACTURER:-}"
  printf 'ro.product.model        = %s\n' "${MTK_PROP_MODEL:-}"
  printf 'ro.product.device       = %s\n' "${MTK_PROP_DEVICE:-}"
  printf 'ro.board.platform       = %s\n' "${MTK_PROP_PLATFORM:-}"
  printf 'ro.hardware             = %s\n' "${MTK_PROP_HARDWARE:-}"
  printf '\n'
  printf 'MediaTek pattern : %s\n' "$MTK_PLATFORM_PATTERN"
  printf 'Ulefone vendor   : %s\n' "$ULEFONE_VENDOR_PATTERN"
  printf 'Ulefone model    : %s\n' "$ULEFONE_MODEL_PATTERN"
  printf 'Pixel vendor     : %s\n' "$PIXEL_VENDOR_PATTERN"
  printf 'Pixel model      : %s\n' "$PIXEL_MODEL_PATTERN"
  printf '\n'
  printf 'Verdict: %s\n' "${MTK_DEVICE_CLASS:-unset}"
  printf 'Reason : %s\n' "${MTK_CLASS_REASON:-unset}"
}

# mtk_assert_mediatek
# A positive assertion, deliberately not "is not a Pixel". Used to gate the
# only script that touches partitions.
mtk_assert_mediatek() {
  if [[ ${MTK_PROP_PLATFORM:-} =~ $MTK_PLATFORM_PATTERN ]]; then
    return 0
  fi
  if [[ ${MTK_PROP_HARDWARE:-} =~ $MTK_PLATFORM_PATTERN ]]; then
    return 0
  fi
  return 1
}

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
