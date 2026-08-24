#!/bin/bash

# ============================================================================
# Fixture tests for the mtk_root toolkit.
#
# Every test runs against a fixture directory (props.txt + by-name.txt) via
# MTK_ROOT_FIXTURE, so no phone is ever touched and the suite is hermetic.
#
# What these tests DO prove: the partition-selection logic, the classification
# refusals, and the read-only guarantee of 10-recon.sh.
# What they do NOT prove: that mtkclient can read any partition on real
# hardware. Fixtures cannot establish that.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly TOOLKIT_DIR="$SCRIPT_DIR/.."
readonly FIXTURES="$SCRIPT_DIR/fixtures"
readonly RECON="$TOOLKIT_DIR/10-recon.sh"
readonly DUMP="$TOOLKIT_DIR/20-dump-stock.sh"

PASS=0
FAIL=0
WORKROOT=""

cleanup() {
  [[ -n $WORKROOT && -d $WORKROOT ]] && rm -rf "$WORKROOT"
}
trap cleanup EXIT

# shellcheck source=./lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

# ---------------------------------------------------------------------------

test_initboot_preferred_over_boot() {
  printf '\ninit_boot is chosen over a co-present boot\n'
  local out=""
  out="$(run_recon ulefone-initboot-ab)"

  # The decisive case: this fixture has BOTH boot_a and init_boot_a. Choosing
  # boot_a here would produce a device that does not boot after flashing.
  assert_contains "selects init_boot_a" "$out" "partition init_boot_a"
  assert_contains "instructs patching INIT_BOOT" "$out" "must patch INIT_BOOT"
  assert_not_contains "does not select boot_a" "$out" "partition boot_a"
  assert_contains "detects A/B" "$out" "A/B scheme      : A/B"
  assert_contains "vbmeta suffixed" "$out" "vbmeta_a"
}

test_a_only_scheme() {
  printf '\nA-only devices get bare partition names\n'
  local out=""
  out="$(run_recon ulefone-initboot-aonly)"

  assert_contains "detects A-only" "$out" "A-only"
  assert_contains "bare init_boot" "$out" "partition init_boot"
  assert_contains "bare vbmeta" "$out" "vbmeta          : vbmeta"
}

test_boot_carrier_when_no_initboot() {
  printf '\nfalls back to boot when init_boot is absent\n'
  local out=""
  out="$(run_recon pixel-boot-ab)"

  assert_contains "selects boot_a" "$out" "partition boot_a"
  assert_contains "instructs patching BOOT" "$out" "must patch BOOT"
  # The word "init_boot" legitimately appears in the explanatory text ("no
  # init_boot present"), so assert on the selection line specifically rather
  # than on the whole report.
  local carrier_line=""
  carrier_line="$(grep 'ramdisk lives in' <<<"$out" || true)"
  assert_contains "carrier reported as boot" "$carrier_line" "ramdisk lives in: boot"
  assert_not_contains "carrier is not init_boot" "$carrier_line" "init_boot"
}

test_unknown_device_refused() {
  printf '\nunknown device is refused, never assumed\n'
  local out="" rc=0
  out="$(run_recon unknown-device)" || rc=$?

  assert_eq "exits non-zero" "$rc" "1"
  assert_contains "says NO PATH" "$out" "NO PATH"
  assert_contains "refuses to guess" "$out" "Refusing to guess"
  # The specific danger: treating "not a Pixel" as "therefore the Ulefone".
  assert_not_contains "does not claim PATH A" "$out" "PATH A"
  assert_not_contains "does not claim PATH B" "$out" "PATH B"
}

test_pixel_is_protected() {
  printf '\nPixel is recognised and refused as a target\n'
  local out=""
  out="$(run_recon pixel-boot-ab)"

  assert_contains "classified PIXEL" "$out" "classified as   : PIXEL"
  assert_contains "indeterminate C/D" "$out" "PATH C or D"
  assert_contains "will not act on it" "$out" "will not act on a Pixel"
}

test_carrier_lock_never_asserted() {
  printf '\ncarrier lock is reported as undetermined, never negative\n'
  local out=""
  out="$(run_recon pixel-boot-ab)"

  assert_contains "reports UNDETERMINED" "$out" "Carrier lock      : UNDETERMINED"
  assert_contains "explains why" "$out" "NOT the same"
  # A false "not carrier locked" would wrongly rule a path back in.
  assert_not_contains "no false negative" "$out" "not carrier locked"
}

test_assumption_banner_always_shown() {
  printf '\npath semantics are flagged as assumed on every run\n'
  local out=""
  for fixture in ulefone-initboot-ab pixel-boot-ab unknown-device; do
    out="$(run_recon "$fixture")" || true
    assert_contains "banner present ($fixture)" "$out" "PATH SEMANTICS ARE ASSUMED"
  done
}

test_recon_is_read_only() {
  printf '\n10-recon.sh contains no mutating command\n'

  local code="" hits=""
  code="$(strip_noncode "$RECON")"

  hits="$(grep -nE '(^|[^[:alnum:]_.-])(fastboot|magiskboot|mtk\.py)([^[:alnum:]_-]|$)' <<<"$code" || true)"
  assert_eq "no fastboot/magiskboot invocation" "${hits:-none}" "none"

  hits="$(grep -nE 'adb[^|]*(reboot|push|install|remount)' <<<"$code" || true)"
  assert_eq "no adb reboot/push/install/remount" "${hits:-none}" "none"

  hits="$(grep -nE 'settings[[:space:]]+put|svc[[:space:]]+(power|data)' <<<"$code" || true)"
  assert_eq "no settings put / svc" "${hits:-none}" "none"

  hits="$(grep -nE '\bdd[[:space:]]+if=|\bmkfs|\berase\b|flashing[[:space:]]+unlock' <<<"$code" || true)"
  assert_eq "no dd/mkfs/erase/unlock" "${hits:-none}" "none"

  # Belt and braces: the only adb subcommands this script may ever run.
  local subcommands=""
  subcommands="$(grep -oE 'mtk_adb[[:space:]]+[a-z-]+' "$RECON" | awk '{ print $2 }' | sort -u | tr '\n' ' ')"
  assert_eq "mtk_adb used only for shell" "${subcommands% }" "shell"
}

test_read_only_scan_catches_injection() {
  printf '\nthe read-only scan actually fails on a mutating command\n'

  # A guard that has never been observed failing is not known to work. Inject
  # real dangerous commands into a copy and assert each is caught. The quoted
  # form is the specific case a previous version of this scan let through.
  local evil="$WORKROOT/evil.sh" code="" hits=""

  sed 's|^  classify_device$|  mtk_adb shell "reboot bootloader"\n  classify_device|' \
    "$RECON" >"$evil"
  code="$(strip_noncode "$evil")"
  hits="$(grep -cE 'adb[^|]*(reboot|push|install|remount)' <<<"$code" || true)"
  if [[ ${hits:-0} -gt 0 ]]; then
    pass "catches quoted 'adb shell \"reboot ...\"'"
  else
    fail "catches quoted 'adb shell \"reboot ...\"'" "injection went undetected"
  fi

  sed 's|^  classify_device$|  fastboot flashing unlock\n  classify_device|' \
    "$RECON" >"$evil"
  code="$(strip_noncode "$evil")"
  hits="$(grep -cE '(^|[^[:alnum:]_.-])(fastboot|magiskboot|mtk\.py)([^[:alnum:]_-]|$)' <<<"$code" || true)"
  if [[ ${hits:-0} -gt 0 ]]; then
    pass "catches bare fastboot invocation"
  else
    fail "catches bare fastboot invocation" "injection went undetected"
  fi

  sed 's|^  classify_device$|  mtk_adb shell settings put global foo 1\n  classify_device|' \
    "$RECON" >"$evil"
  code="$(strip_noncode "$evil")"
  hits="$(grep -cE 'settings[[:space:]]+put|svc[[:space:]]+(power|data)' <<<"$code" || true)"
  if [[ ${hits:-0} -gt 0 ]]; then
    pass "catches settings put"
  else
    fail "catches settings put" "injection went undetected"
  fi

  # And the scan must still pass on the real, unmodified script.
  code="$(strip_noncode "$RECON")"
  hits="$(grep -nE 'adb[^|]*(reboot|push|install|remount)' <<<"$code" || true)"
  assert_eq "no false positive on the real script" "${hits:-none}" "none"
}

# shellcheck source=./lib/dump_tests.sh
source "$SCRIPT_DIR/lib/dump_tests.sh"

main() {
  WORKROOT="$(mktemp -d)"
  readonly WORKROOT
  mkdir -p "$WORKROOT/cache"

  printf '=== mtk_root fixture tests ===\n'

  test_initboot_preferred_over_boot
  test_a_only_scheme
  test_boot_carrier_when_no_initboot
  test_unknown_device_refused
  test_pixel_is_protected
  test_carrier_lock_never_asserted
  test_assumption_banner_always_shown
  test_recon_is_read_only
  test_read_only_scan_catches_injection
  test_dump_refuses_non_mediatek
  test_dump_happy_path
  test_dump_rejects_truncated_image
  test_dump_requires_recon_first
  test_facts_file_written

  printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]]
}

main "$@"
