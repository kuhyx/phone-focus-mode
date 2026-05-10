#!/bin/bash
# Regression tests for android_guardian service loop cadence.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_SCRIPT="$REPO_DIR/scripts/utils/android_guardian/service.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$context (expected: '$expected', actual: '$actual')"
  fi
}

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WORKTREE="$TMP_DIR/worktree"
mkdir -p "$WORKTREE/scripts/utils/android_guardian"
cp "$TARGET_SCRIPT" "$WORKTREE/scripts/utils/android_guardian/service.sh"

printf 'Checking skip-main avoids boot side effects...\n'
SKIP_MAIN_GUARDIAN_DIR="$TMP_DIR/skip-main-guardian"
ANDROID_GUARDIAN_SKIP_MAIN=1 \
ANDROID_GUARDIAN_DIR="$SKIP_MAIN_GUARDIAN_DIR" \
ANDROID_GUARDIAN_MODULE_DIR="$TMP_DIR/skip-main-module" \
sh "$TARGET_SCRIPT"

[[ ! -d "$SKIP_MAIN_GUARDIAN_DIR" ]] \
  || fail 'skip-main should prevent guardian boot setup side effects'

printf 'Checking guardian loop cadence constants...\n'
hosts_ticks=$(grep '^HOSTS_CHECK_EVERY_TICKS=' "$WORKTREE/scripts/utils/android_guardian/service.sh" | cut -d= -f2)
apps_ticks=$(grep '^APPS_CHECK_EVERY_TICKS=' "$WORKTREE/scripts/utils/android_guardian/service.sh" | cut -d= -f2)
sleep_seconds=$(grep '^LOOP_SLEEP_SECONDS=' "$WORKTREE/scripts/utils/android_guardian/service.sh" | cut -d= -f2)

assert_equals '6' "$hosts_ticks" 'hosts protection should run every 6 ticks'
assert_equals '12' "$apps_ticks" 'blocked-app scan should run every 12 ticks'
assert_equals '5' "$sleep_seconds" 'guardian loop should keep the 5 second base sleep'

printf 'Checking guardian loop protects module every tick...\n'
grep -q 'protect_module' "$WORKTREE/scripts/utils/android_guardian/service.sh" \
  || fail 'guardian loop must always protect the module each tick'

printf 'Checking blocked-app scans are cached per pass...\n'
grep -q 'installed_packages=$(pm list packages 2>/dev/null)' "$WORKTREE/scripts/utils/android_guardian/service.sh" \
  || fail 'guardian service should cache installed packages once per blocked-app scan'

if grep -q 'pm list packages 2>/dev/null | grep -q' "$WORKTREE/scripts/utils/android_guardian/service.sh"; then
  fail 'guardian service should not re-run pm list packages through grep for every blocked app'
fi

printf 'Checking guardian loop uses skip-main guard for tests...\n'
grep -q 'ANDROID_GUARDIAN_SKIP_MAIN' "$WORKTREE/scripts/utils/android_guardian/service.sh" \
  || fail 'guardian service should support skip-main testing'

printf 'android_guardian service regression checks passed.\n'
