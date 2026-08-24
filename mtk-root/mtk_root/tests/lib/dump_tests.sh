#!/bin/bash

# ============================================================================
# Fixture tests for 20-dump-stock.sh: refusals, the happy path, truncation
# detection, ordering against 10-recon.sh, and the facts file it writes.
#
# Split out of run_tests.sh to keep both files under the 250-line cap. Sourced
# by run_tests.sh, which owns the counters and the fixture paths these use.
# ============================================================================

# shellcheck shell=bash

test_dump_refuses_non_mediatek() {
  printf '\n20-dump-stock.sh refuses a non-MediaTek device\n'
  [[ -x $DUMP ]] || {
    fail "20-dump-stock.sh present" "not found or not executable"
    return 0
  }

  local out="" rc=0
  out="$(MTK_ROOT_FIXTURE="$FIXTURES/pixel-boot-ab" \
    MTK_ROOT_CACHE="$WORKROOT/cache" \
    MTK_SERIAL="TESTPIXEL" \
    "$DUMP" --yes 2>&1)" || rc=$?

  assert_eq "exits non-zero on Pixel" "$rc" "1"
  assert_contains "refuses explicitly" "$out" "refus"
  assert_not_contains "no dump attempted" "$out" "Dumping"
}

test_dump_happy_path() {
  printf '\n20-dump-stock.sh produces a manifest from a stubbed read\n'
  [[ -x $DUMP ]] || {
    fail "20-dump-stock.sh present" "not found or not executable"
    return 0
  }

  # Stub stands in for mtkclient: writes a plausibly-sized file. This exercises
  # find_latest_facts, read_facts_value, verify_dump, the size band, the sha256
  # column and the manifest - none of which the refusal test reaches.
  local stub="$WORKROOT/stub-dump.sh"
  cat >"$stub" <<'STUB'
#!/bin/bash
set -euo pipefail
truncate -s 8M "$2"
printf 'ANDROID!' | dd of="$2" conv=notrunc status=none
STUB
  chmod +x "$stub"

  local cache="$WORKROOT/dumpcache"
  mkdir -p "$cache"
  local serial="DUMPTEST1"

  # Chain the real recon output in, rather than hand-writing a facts file:
  # this also proves the two scripts agree on the format.
  MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$cache" MTK_SERIAL="$serial" "$RECON" >/dev/null 2>&1

  local out="" rc=0
  out="$(MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$cache" MTK_SERIAL="$serial" \
    MTK_DUMP_CMD="$stub" "$DUMP" --yes 2>&1)" || rc=$?

  assert_eq "exits zero on success" "$rc" "0"
  assert_contains "dumped the init_boot partition" "$out" "init_boot_a"

  local manifest="$cache/stock/$serial/manifest.txt"
  if [[ ! -f $manifest ]]; then
    fail "manifest written" "not found at $manifest"
    return 0
  fi
  pass "manifest written"

  local content=""
  content="$(cat "$manifest")"
  assert_contains "manifest names the image" "$content" "init_boot_a.img"
  assert_contains "manifest records vbmeta" "$content" "vbmeta_a.img"
  assert_contains "manifest records carrier" "$content" "ramdisk_carrier=init_boot"
  assert_contains "manifest records size" "$content" "8388608 bytes"
  # A sha256 is 64 hex chars; assert one is actually present.
  if grep -qE '^[0-9a-f]{64}  ' <<<"$content"; then
    pass "manifest records sha256"
  else
    fail "manifest records sha256" "no 64-char hex digest found"
  fi

  # Idempotence: a second run must not silently re-dump over a good backup.
  out="$(MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$cache" MTK_SERIAL="$serial" \
    MTK_DUMP_CMD="$stub" "$DUMP" --yes 2>&1)" || true
  assert_contains "second run is a no-op" "$out" "already exists"
}

test_dump_rejects_truncated_image() {
  printf '\n20-dump-stock.sh flags an implausibly small dump\n'
  [[ -x $DUMP ]] || return 0

  # mtkclient exits 0 on a truncated read, so size is the only signal that the
  # "backup" is worthless. A 512-byte init_boot must not pass silently.
  local stub="$WORKROOT/stub-truncated.sh"
  cat >"$stub" <<'STUB'
#!/bin/bash
set -euo pipefail
truncate -s 512 "$2"
STUB
  chmod +x "$stub"

  local cache="$WORKROOT/truncache"
  mkdir -p "$cache"
  local serial="DUMPTEST2"

  MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$cache" MTK_SERIAL="$serial" "$RECON" >/dev/null 2>&1

  local out="" rc=0
  out="$(MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$cache" MTK_SERIAL="$serial" \
    MTK_DUMP_CMD="$stub" "$DUMP" --yes 2>&1)" || rc=$?

  assert_eq "exits non-zero" "$rc" "1"
  assert_contains "calls it implausibly small" "$out" "implausibly small"
  assert_contains "warns against trusting it" "$out" "Do NOT treat this as a usable backup"
}

test_dump_requires_recon_first() {
  printf '\n20-dump-stock.sh refuses without a recon facts file\n'
  [[ -x $DUMP ]] || return 0

  local out="" rc=0
  out="$(MTK_ROOT_FIXTURE="$FIXTURES/ulefone-initboot-ab" \
    MTK_ROOT_CACHE="$WORKROOT/emptycache" MTK_SERIAL="NOFACTS1" \
    MTK_DUMP_CMD="/bin/true" "$DUMP" --yes 2>&1)" || rc=$?

  assert_eq "exits non-zero" "$rc" "1"
  assert_contains "points at 10-recon.sh" "$out" "10-recon.sh"
  assert_contains "explains it will not guess" "$out" "rather than guessing"
}

test_facts_file_written() {
  printf '\nfacts file is written and machine-readable\n'
  local out="" facts=""
  out="$(run_recon ulefone-initboot-ab)"

  facts="$(find "$WORKROOT/cache" -name 'device-facts-ULEFONE-*.txt' -print -quit 2>/dev/null)"
  if [[ -z $facts ]]; then
    fail "facts file created" "none found under $WORKROOT/cache"
    return 0
  fi
  pass "facts file created"

  local content=""
  content="$(cat "$facts")"
  assert_contains "records ramdisk partition" "$content" "ramdisk_partition=init_boot_a"
  assert_contains "records carrier" "$content" "ramdisk_carrier=init_boot"
  assert_contains "records scheme" "$content" "ab_scheme=A/B"
  assert_contains "includes by-name listing" "$content" "[by-name]"
}
