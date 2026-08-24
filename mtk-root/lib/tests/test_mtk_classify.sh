#!/usr/bin/env bash
# Covers classify_device, mtk_assert_mediatek, mtk_explain_classification
# and mtk_sanitize, all through the MTK_ROOT_FIXTURE seam.
#
# The load-bearing assertion here is the THIRD PHONE case. classify_device's
# contract is that ULEFONE requires a MediaTek signal AND a vendor/model
# match — both, never either — so an unrelated MediaTek handset must land in
# UNKNOWN rather than being treated as the Ulefone. Every caller refuses to
# act on UNKNOWN, and that is what stops this toolkit flashing a stranger's
# phone. A rule rewritten to `||` would still pass the ULEFONE and PIXEL
# cases below; only this one catches it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mtk_harness.sh
source "$HERE/mtk_harness.sh"

_t_sandbox
# shellcheck source=../mtk_common.sh
source "$HERE/../mtk_common.sh"

# --- classify_device -------------------------------------------------------

MTK_ROOT_FIXTURE="$(_t_fixture ulefone \
	'ro.product.manufacturer=Ulefone
ro.product.model=Armor 26 Ultra
ro.board.platform=mt6989
ro.hardware=mt6989
ro.product.device=Armor26Ultra' 'boot_a')"
export MTK_ROOT_FIXTURE
classify_device
_t_is "ULEFONE" "$MTK_DEVICE_CLASS" "MediaTek platform + Ulefone vendor -> ULEFONE"
_t_in "MediaTek platform" "$MTK_CLASS_REASON" "ULEFONE reason names the platform signal"

MTK_ROOT_FIXTURE="$(_t_fixture pixel \
	'ro.product.manufacturer=Google
ro.product.model=Pixel 6a
ro.board.platform=gs101
ro.hardware=oriole
ro.product.device=bluejay' 'boot_a')"
classify_device
_t_is "PIXEL" "$MTK_DEVICE_CLASS" "Google + Pixel identity -> PIXEL"

# A MediaTek phone that is NOT the Ulefone. The single most important case:
# "not a Pixel, so presumably the Ulefone" is exactly the reasoning the
# implementation refuses, and it is what would target the wrong hardware.
MTK_ROOT_FIXTURE="$(_t_fixture third_party \
	'ro.product.manufacturer=Xiaomi
ro.product.model=Redmi Note 12
ro.board.platform=mt6833
ro.hardware=mt6833
ro.product.device=tapas' 'boot_a')"
classify_device
_t_is "UNKNOWN" "$MTK_DEVICE_CLASS" "MediaTek but wrong vendor -> UNKNOWN, not ULEFONE"

# Ulefone identity with no MediaTek signal is equally not enough.
MTK_ROOT_FIXTURE="$(_t_fixture ulefone_no_mtk \
	'ro.product.manufacturer=Ulefone
ro.product.model=Armor 26 Ultra
ro.board.platform=sm8650
ro.hardware=qcom
ro.product.device=Armor26Ultra' 'boot_a')"
classify_device
_t_is "UNKNOWN" "$MTK_DEVICE_CLASS" "Ulefone identity without MediaTek -> UNKNOWN"

# An unauthorized device answers every getprop with an empty string. That must
# not resolve to a class.
MTK_ROOT_FIXTURE="$(_t_fixture empty '' 'boot_a')"
classify_device
_t_is "UNKNOWN" "$MTK_DEVICE_CLASS" "no properties at all -> UNKNOWN"
_t_in "no rule matched" "$MTK_CLASS_REASON" "UNKNOWN reason explains which reads were empty"

# --- mtk_assert_mediatek ---------------------------------------------------

# A positive assertion, deliberately not "is not a Pixel". It gates the only
# script that touches partitions, so both directions are asserted.
MTK_ROOT_FIXTURE="$(_t_fixture assert_mtk \
	'ro.board.platform=mt6989
ro.hardware=mt6989' 'boot_a')"
classify_device
_t_rc 0 "mtk_assert_mediatek accepts an mt#### platform" mtk_assert_mediatek

MTK_ROOT_FIXTURE="$(_t_fixture assert_qcom \
	'ro.board.platform=sm8650
ro.hardware=qcom' 'boot_a')"
classify_device
_t_rc 1 "mtk_assert_mediatek rejects a non-MediaTek platform" mtk_assert_mediatek

# hardware alone is enough — some devices report the SoC there and leave
# ro.board.platform unset.
MTK_ROOT_FIXTURE="$(_t_fixture assert_hw_only 'ro.hardware=mt8183' 'boot_a')"
classify_device
_t_rc 0 "mtk_assert_mediatek accepts a MediaTek ro.hardware alone" mtk_assert_mediatek

# --- mtk_explain_classification --------------------------------------------

explain_out="$(mtk_explain_classification 2>&1)"
_t_in "Verdict:" "$explain_out" "explain output states a verdict"
_t_in "mt8183" "$explain_out" "explain output echoes the property it read"

# --- mtk_sanitize ----------------------------------------------------------

# adb shell returns CRLF, which silently breaks string comparisons — the
# reason this function exists at all.
_t_is "mt6989" "$(mtk_sanitize "$(printf 'mt6989\r')")" "sanitize strips a trailing CR"
_t_is "Armor 26 Ultra" "$(mtk_sanitize 'Armor 26 Ultra')" "sanitize keeps spaces and digits"
# tr -cd DELETES disallowed bytes rather than truncating at the first one, so
# the alphanumerics inside a substitution survive as inert text. What matters
# is that $ ( ) ` ; & | cannot come back out.
# The metacharacters are assembled from \-escapes rather than written inside
# single quotes, so that "these must not expand" is stated in the code rather
# than left to the reader (and to shellcheck) to infer.
hostile="rm -rf \$(whoami)\`id\`; reboot & echo|x"
sanitized="$(mtk_sanitize "$hostile")"
_t_is "rm -rf whoamiid reboot  echox" "$sanitized" "sanitize deletes shell metacharacters"
for meta in '$' '(' ')' '`' ';' '&' '|'; do
	_t_is "" "${sanitized//[^"$meta"]/}" "sanitize leaves no '${meta}' behind"
done

_t_done "test_mtk_classify.sh"
