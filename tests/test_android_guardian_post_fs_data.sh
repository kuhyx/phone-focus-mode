#!/bin/bash
# Regression tests for android_guardian post-fs-data watchdog generation.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_SCRIPT="$REPO_DIR/scripts/periodic_background/utils/android_guardian/post-fs-data.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local pattern="$2"
  local context="$3"
  grep -q -- "$pattern" "$file_path" || fail "$context"
}

assert_file_not_contains() {
  local file_path="$1"
  local pattern="$2"
  local context="$3"
  if grep -q -- "$pattern" "$file_path"; then
    fail "$context"
  fi
}

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

GUARDIAN_DIR="$TMP_DIR/guardian"
MODULE_DIR="$TMP_DIR/module"
WATCHDOG_SCRIPT="$GUARDIAN_DIR/watchdog.sh"
mkdir -p "$GUARDIAN_DIR" "$MODULE_DIR/system/etc"

printf 'Generating watchdog script in a temp Android guardian directory...\n'
ANDROID_GUARDIAN_DIR="$GUARDIAN_DIR" \
ANDROID_GUARDIAN_MODULE_DIR="$MODULE_DIR" \
ANDROID_GUARDIAN_WATCHDOG_SCRIPT="$WATCHDOG_SCRIPT" \
ANDROID_GUARDIAN_POST_FS_SKIP_WATCHDOG_START=1 \
sh "$TARGET_SCRIPT"

[[ -f "$WATCHDOG_SCRIPT" ]] || fail 'watchdog script should be generated'
[[ -x "$WATCHDOG_SCRIPT" ]] || fail 'watchdog script should be executable'

printf 'Checking generated watchdog cadence and lower-fork host protection...\n'
assert_file_contains "$WATCHDOG_SCRIPT" '^HOSTS_CHECK_EVERY_TICKS=10$' \
  'watchdog should throttle host protection to every 10 ticks'
assert_file_contains "$WATCHDOG_SCRIPT" '^LOOP_SLEEP_SECONDS=3$' \
  'watchdog should keep the 3 second base sleep'
assert_file_contains "$WATCHDOG_SCRIPT" 'cmp -s' \
  'watchdog should use cmp for host integrity checks'
assert_file_not_contains "$WATCHDOG_SCRIPT" 'md5sum' \
  'watchdog should not use md5sum in the hot loop anymore'
assert_file_not_contains "$WATCHDOG_SCRIPT" 'cut -d' \
  'watchdog should not pipe hashes through cut anymore'

printf 'Checking test hooks and generation log entry...\n'
assert_file_contains "$TARGET_SCRIPT" 'ANDROID_GUARDIAN_POST_FS_SKIP_MAIN' \
  'post-fs-data should support skipping main for tests'
assert_file_contains "$TARGET_SCRIPT" 'ANDROID_GUARDIAN_POST_FS_SKIP_WATCHDOG_START' \
  'post-fs-data should support generating without starting the watchdog'
assert_file_contains "$GUARDIAN_DIR/guardian.log" 'Watchdog generation complete (start skipped)' \
  'post-fs-data should log skipped watchdog starts during tests'

printf 'android_guardian post-fs-data regression checks passed.\n'
