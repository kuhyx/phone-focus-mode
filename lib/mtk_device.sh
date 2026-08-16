#!/bin/bash
# adb wrappers, device listing, selection and authorisation.
#
# Sourced by mtk_common.sh, which stays the single entry point the
# mtk_root scripts source, so their public surface is unchanged.

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
