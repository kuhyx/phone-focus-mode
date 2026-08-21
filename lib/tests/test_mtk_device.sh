#!/usr/bin/env bash
# Covers mtk_list_devices, mtk_device_state, mtk_select_device and
# mtk_require_authorized.
#
# The load-bearing case is REFUSING TO GUESS. With two phones attached and no
# --serial, mtk_select_device must fail rather than pick one: a wrong choice
# here points a partition-flashing toolkit at the wrong device. A version
# that took serials[0] would pass every other assertion in this file.
#
# adb is shimmed onto PATH rather than mocked in-process, because
# mtk_list_devices calls the binary directly. _t_adb_says writes the shim's
# canned `adb devices` output; nothing here talks to real hardware, and the
# shim refuses any subcommand the tests do not expect.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mtk_harness.sh
source "$HERE/mtk_harness.sh"

_t_sandbox
# shellcheck source=../mtk_common.sh
source "$HERE/../mtk_common.sh"

# --- adb shim --------------------------------------------------------------

# Narrow PATH to a shim dir. Every external these functions reach for must be
# seeded here: a missing one aborts the suite under `set -e` with no stderr.
_t_shim_dir="$T_TMP/bin"
mkdir -p "$_t_shim_dir"
cat >"$_t_shim_dir/adb" <<'SHIM'
#!/usr/bin/env bash
# Test double. Prints the canned `adb devices` table and nothing else; any
# other subcommand is a bug in the test, so say so loudly rather than
# returning an empty string that would read as "no devices".
if [[ ${1:-} == "devices" ]]; then
	cat "${T_ADB_DEVICES:?}"
	exit 0
fi
printf 'adb shim: unexpected invocation: %s\n' "$*" >&2
exit 97
SHIM
chmod +x "$_t_shim_dir/adb"
for _t_ext in awk mapfile cat printf; do
	_t_bin="$(command -v "$_t_ext" 2>/dev/null || true)"
	[[ -n $_t_bin ]] && ln -sf "$_t_bin" "$_t_shim_dir/$_t_ext"
done
PATH="$_t_shim_dir:/usr/bin:/bin"
export PATH

T_ADB_DEVICES="$T_TMP/adb_devices.txt"
export T_ADB_DEVICES

_t_adb_says() {
	printf 'List of devices attached\n%s\n' "$1" >"$T_ADB_DEVICES"
}

# --- mtk_list_devices ------------------------------------------------------

_t_adb_says 'ABC123	device'
_t_is "ABC123 device" "$(mtk_list_devices)" "one attached device is listed with its state"

_t_adb_says 'ABC123	device
DEF456	unauthorized'
_t_is "2" "$(mtk_list_devices | wc -l)" "both attached devices are listed"

# A blank table is what an empty `adb devices` looks like.
_t_adb_says ''
_t_is "" "$(mtk_list_devices)" "no attached devices lists nothing"

# --- mtk_device_state ------------------------------------------------------

_t_adb_says 'ABC123	device
DEF456	unauthorized
GHI789	offline'
_t_is "device" "$(mtk_device_state ABC123)" "an authorized device reports 'device'"
_t_is "unauthorized" "$(mtk_device_state DEF456)" "an unauthorized device reports so"
_t_is "offline" "$(mtk_device_state GHI789)" "an offline device reports so"
_t_is "absent" "$(mtk_device_state NOPE000)" "an unattached serial reports 'absent'"

# --- mtk_select_device -----------------------------------------------------

_t_adb_says 'ABC123	device'
unset MTK_SERIAL
_t_rc 0 "a single attached device is selected" mtk_select_device
unset MTK_SERIAL
mtk_select_device
_t_is "ABC123" "$MTK_SERIAL" "the selected serial is the attached one"

# Two devices, no request: must refuse.
_t_adb_says 'ABC123	device
DEF456	device'
unset MTK_SERIAL
_t_rc 1 "two devices with no --serial refuses to guess" mtk_select_device
unset MTK_SERIAL
refuse_out="$(mtk_select_device 2>&1 || true)"
_t_in "refusing to guess" "$refuse_out" "the refusal says why"
_t_in "--serial" "$refuse_out" "the refusal names the way out"

# Two devices WITH a request: the named one is honoured.
unset MTK_SERIAL
mtk_select_device DEF456
_t_is "DEF456" "$MTK_SERIAL" "an explicit serial disambiguates"

# A requested serial that is not attached must fail, not fall back.
unset MTK_SERIAL
_t_rc 1 "a requested serial that is absent fails" mtk_select_device ZZZ999
unset MTK_SERIAL
_t_in "is not attached" "$(mtk_select_device ZZZ999 2>&1 || true)" \
	"the absent-serial error names the problem"

# No devices at all.
_t_adb_says ''
unset MTK_SERIAL
_t_rc 1 "no attached devices fails" mtk_select_device
unset MTK_SERIAL
_t_in "No device visible" "$(mtk_select_device 2>&1 || true)" "the no-device error is actionable"

# --- mtk_require_authorized ------------------------------------------------

_t_adb_says 'ABC123	device
DEF456	unauthorized
GHI789	offline'

MTK_SERIAL=ABC123
_t_rc 0 "an authorized device passes the gate" mtk_require_authorized

# The case this function exists for: an unauthorized device answers every
# getprop with an empty string, which reads exactly like "no properties".
MTK_SERIAL=DEF456
_t_rc 1 "an unauthorized device is caught up front" mtk_require_authorized
_t_in "UNAUTHORIZED" "$(mtk_require_authorized 2>&1 || true)" \
	"the unauthorized error blames the prompt, not the device"

MTK_SERIAL=GHI789
_t_rc 1 "an offline device is caught" mtk_require_authorized
_t_in "OFFLINE" "$(mtk_require_authorized 2>&1 || true)" "the offline error is actionable"

MTK_SERIAL=NOPE000
_t_rc 1 "an absent device is caught" mtk_require_authorized

# Under a fixture both selection and authorization are bypassed entirely,
# which is what keeps the rest of this directory's suites offline.
MTK_ROOT_FIXTURE="$(_t_fixture selectable '' 'boot')"
export MTK_ROOT_FIXTURE
unset MTK_SERIAL
_t_rc 0 "a fixture selects without adb" mtk_select_device
unset MTK_SERIAL
mtk_select_device
_t_is "fixture" "$MTK_SERIAL" "the fixture serial is a placeholder"
_t_rc 0 "a fixture is always authorized" mtk_require_authorized

_t_done "test_mtk_device.sh"
