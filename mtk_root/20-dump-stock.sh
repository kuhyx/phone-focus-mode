#!/bin/bash

# ============================================================================
# 20-dump-stock.sh - Dump the stock ramdisk + vbmeta off a MediaTek device.
#
# This is the reason the Ulefone firmware is not pre-downloaded: the stock
# images come off the device itself, so they match this exact unit and build.
#
# Reading requires mtkclient and BROM/preloader mode - the phone must be
# powered OFF and plugged in while mtkclient waits. Reading a partition does
# not modify it, but this is the first script here that talks to the bootrom,
# so it refuses loudly rather than proceeding on a guess.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# shellcheck source=../lib/mtk_common.sh
source "$SCRIPT_DIR/../lib/mtk_common.sh"

REQUESTED_SERIAL=""
ASSUME_YES=0
FORCE=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--serial <serial>] [--yes] [--force] [--help]

Dumps the stock ramdisk-carrying partition and vbmeta from a MediaTek device
using mtkclient, then records sizes and sha256 sums.

  --serial <serial>  Target device (required if more than one is attached)
  --yes              Skip the confirmation prompt
  --force            Re-dump even if a complete dump already exists
  --help             This text

Refuses unless the device is positively identified as MediaTek. Never runs
against a Pixel or an unclassified device.
EOF
  exit 0
}

# find_latest_facts <serial>
# The ramdisk partition name is read from the recon facts file rather than
# re-derived here. One source of truth, and it guarantees a dump can only ever
# target a partition that a human has already seen in a recon report.
find_latest_facts() {
  local serial="$1" cache_dir=""
  cache_dir="$(mtk_cache_dir)"

  # A missing cache dir is an ordinary "no recon has run yet", not an error.
  # Without the guard, `find` on a nonexistent path fails under `set -e` and
  # the script exits silently before it can explain what to do instead.
  [[ -d $cache_dir ]] || return 0

  find "$cache_dir" -maxdepth 1 -name "device-facts-*-${serial}-*.txt" 2>/dev/null |
    sort | tail -n 1
}

read_facts_value() {
  local facts="$1" key="$2" line=""
  line="$(grep -m1 -- "^${key}=" "$facts" 2>/dev/null || true)"
  printf '%s' "${line#*=}"
}

# dump_partition <partition> <destination>
#
# MTK_DUMP_CMD overrides the mtkclient invocation and is the seam the tests
# use: it is called as `$MTK_DUMP_CMD <partition> <destination>`. Without it
# the only way to exercise the manifest/verification logic below would be to
# attach a phone in BROM mode, so that code would ship unrun.
dump_partition() {
  local partition="$1" dest="$2"
  local mtk_dir="" python_bin=""

  mtk_info "Dumping ${partition} -> ${dest}"

  if [[ -n ${MTK_DUMP_CMD:-} ]]; then
    # shellcheck disable=SC2086  # intentional word splitting: the override may
    # carry arguments, e.g. MTK_DUMP_CMD="./stub.sh --size 4M"
    ${MTK_DUMP_CMD} "$partition" "$dest"
    return $?
  fi

  mtk_dir="$(mtk_mtkclient_dir)"
  python_bin="$(mtk_venv_python)"

  mtk_info "mtkclient is waiting for the device in BROM/preloader mode."
  mtk_info "Power the phone OFF, then connect USB (some units need vol- held)."

  # `mtk.py r <partition> <outfile>` per the mtkclient README. Run from the
  # clone directory because mtk.py resolves its Loader/ paths relative to cwd.
  (
    cd "$mtk_dir" || exit 1
    "$python_bin" mtk.py r "$partition" "$dest"
  )
}

verify_dump() {
  local label="$1" path="$2"
  local size="" verdict="" sha=""

  if [[ ! -f $path ]]; then
    mtk_error "${label}: no file produced at ${path}"
    return 1
  fi

  size="$(mtk_file_size "$path")"
  sha="$(mtk_sha256 "$path")"

  if verdict="$(mtk_sane_ramdisk_size "$size")"; then
    mtk_info "${label}: ${verdict}, sha256 ${sha}"
  else
    # mtkclient exits 0 on a truncated read, so size is the only signal that
    # something went wrong short of parsing the image.
    mtk_warn "${label}: ${verdict}"
    mtk_warn "${label}: sha256 ${sha}"
    mtk_warn "Inspect this image before trusting it as a backup."
    return 1
  fi
  return 0
}

main() {
  printf '\033[1m%s - stock partition dump (MediaTek only)\033[0m\n' "$SCRIPT_NAME"

  if ! mtk_select_device "$REQUESTED_SERIAL"; then
    exit 1
  fi

  if [[ -z ${MTK_ROOT_FIXTURE:-} ]] && ! mtk_require_authorized; then
    exit 1
  fi

  classify_device

  # Positive assertion, in two independent parts. Deliberately never phrased
  # as "not a Pixel": an unrecognised third device must fail here too.
  if [[ $MTK_DEVICE_CLASS != "ULEFONE" ]]; then
    mtk_error "Device classified as ${MTK_DEVICE_CLASS}; refusing to dump."
    mtk_error "Reason: ${MTK_CLASS_REASON}"
    mtk_error "This script only ever runs against a MediaTek Ulefone target."
    exit 1
  fi

  if ! mtk_assert_mediatek; then
    mtk_error "No MediaTek platform signal on this device; refusing to dump."
    mtk_error "platform='${MTK_PROP_PLATFORM:-}' hardware='${MTK_PROP_HARDWARE:-}'"
    exit 1
  fi

  local facts=""
  facts="$(find_latest_facts "$MTK_SERIAL")"
  if [[ -z $facts ]]; then
    mtk_error "No recon facts file found for ${MTK_SERIAL}."
    mtk_error "Run ./10-recon.sh --serial ${MTK_SERIAL} first - this script"
    mtk_error "reads the partition names from that report rather than guessing."
    exit 1
  fi
  mtk_info "Using facts: ${facts}"

  local ramdisk_part="" vbmeta_part="" carrier=""
  ramdisk_part="$(read_facts_value "$facts" ramdisk_partition)"
  vbmeta_part="$(read_facts_value "$facts" vbmeta_partition)"
  carrier="$(read_facts_value "$facts" ramdisk_carrier)"

  if [[ -z $ramdisk_part ]]; then
    mtk_error "Facts file records no ramdisk partition. Re-run 10-recon.sh."
    exit 1
  fi

  # Skipped when the dump command is overridden, since mtkclient is then not
  # the thing doing the reading.
  if [[ -z ${MTK_DUMP_CMD:-} ]]; then
    local venv_status=""
    if ! venv_status="$(mtk_check_venv)"; then
      mtk_error "mtkclient venv unusable: ${venv_status}"
      mtk_error "Run ./install.sh, then ./00-preflight.sh."
      exit 1
    fi
  fi

  local out_dir=""
  out_dir="$(mtk_stock_dir)/${MTK_SERIAL}"

  if [[ -f "${out_dir}/manifest.txt" && $FORCE -eq 0 ]]; then
    mtk_info "A dump already exists at ${out_dir}"
    mtk_info "Re-run with --force to replace it. Existing manifest:"
    cat "${out_dir}/manifest.txt"
    exit 0
  fi

  mtk_heading "About to dump"
  printf '  device    : %s (%s)\n' "$MTK_SERIAL" "${MTK_PROP_MODEL:-}"
  printf '  ramdisk   : %s (carrier: %s)\n' "$ramdisk_part" "${carrier:-unknown}"
  printf '  vbmeta    : %s\n' "${vbmeta_part:-<none found>}"
  printf '  output    : %s\n' "$out_dir"
  printf '\n  Reading is non-destructive, but it needs BROM/preloader mode.\n'

  if [[ $ASSUME_YES -eq 0 ]]; then
    local reply=""
    read -r -p "  Proceed? [y/N] " reply
    if [[ ${reply,,} != "y" ]]; then
      mtk_info "Aborted by user."
      exit 0
    fi
  fi

  mkdir -p "$out_dir"

  local failures=0
  local ramdisk_file="${out_dir}/${ramdisk_part}.img"
  if dump_partition "$ramdisk_part" "$ramdisk_file"; then
    verify_dump "$ramdisk_part" "$ramdisk_file" || failures=$((failures + 1))
  else
    mtk_error "mtkclient failed to read ${ramdisk_part}"
    failures=$((failures + 1))
  fi

  if [[ -n $vbmeta_part ]]; then
    local vbmeta_file="${out_dir}/${vbmeta_part}.img"
    if dump_partition "$vbmeta_part" "$vbmeta_file"; then
      # vbmeta is legitimately far smaller than a ramdisk carrier, so the
      # ramdisk size band does not apply; record it without a band check.
      if [[ -f $vbmeta_file ]]; then
        mtk_info "${vbmeta_part}: $(mtk_file_size "$vbmeta_file") bytes, sha256 $(mtk_sha256 "$vbmeta_file")"
      else
        mtk_error "${vbmeta_part}: no file produced"
        failures=$((failures + 1))
      fi
    else
      mtk_error "mtkclient failed to read ${vbmeta_part}"
      failures=$((failures + 1))
    fi
  fi

  # Manifest is plain text on purpose: it is the only artifact here that may
  # be committed. The images themselves stay in the cache dir.
  {
    printf '# mtk_root stock dump manifest\n'
    printf 'generated=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'serial=%s\n' "$MTK_SERIAL"
    printf 'model=%s\n' "${MTK_PROP_MODEL:-}"
    printf 'fingerprint=%s\n' "$(read_facts_value "$facts" ro.build.fingerprint)"
    printf 'ramdisk_carrier=%s\n' "${carrier:-}"
    printf '\n'
    local f=""
    for f in "$out_dir"/*.img; do
      [[ -f $f ]] || continue
      printf '%s  %s  %s bytes\n' "$(mtk_sha256 "$f")" "${f##*/}" "$(mtk_file_size "$f")"
    done
  } >"${out_dir}/manifest.txt"

  mtk_heading "Result"
  cat "${out_dir}/manifest.txt"

  if [[ $failures -gt 0 ]]; then
    mtk_error "${failures} problem(s) above. Do NOT treat this as a usable backup."
    exit 1
  fi

  mtk_info "Stock images saved to ${out_dir}"
  mtk_info "Back these up off this machine before flashing anything."
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
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --force)
      FORCE=1
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
