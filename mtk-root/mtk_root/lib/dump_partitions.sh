#!/bin/bash
# Reading facts and dumping individual partitions.
#
# Sourced by 20-dump-stock.sh; split out to keep it under the 250-line cap.
# Sourced rather than run, so it inherits the caller's strict mode and
# the helper functions and variables defined above the source line.

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
