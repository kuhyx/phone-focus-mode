#!/bin/bash
# Dump verification and reporting for the stock partition dump.
#
# Sourced by 20-dump-stock.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and
# the helper functions and variables defined above the source line.

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
