#!/bin/bash
# Device classification, partition discovery and layout checks.
#
# Sourced by mtk_common.sh, which stays the single entry point the
# mtk_root scripts source, so their public surface is unchanged.

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
