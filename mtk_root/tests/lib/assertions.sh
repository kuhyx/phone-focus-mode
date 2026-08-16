#!/bin/bash

# ============================================================================
# Assertion helpers and fixture drivers for the mtk_root fixture tests.
#
# Split out of run_tests.sh to keep it under the 250-line cap. The seam passes
# state deliberately: pass/fail increment the caller's PASS and FAIL counters,
# and run_recon reads WORKROOT, FIXTURES and RECON. The caller defines all of
# them before sourcing this file.
# ============================================================================

# shellcheck shell=bash

pass() {
  PASS=$((PASS + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  [FAIL] %s\n' "$1"
  [[ -n ${2:-} ]] && printf '         %s\n' "$2"
  return 0
}

assert_contains() {
  if [[ $2 == *"$3"* ]]; then
    pass "$1"
  else
    fail "$1" "expected to find: $3"
  fi
}

assert_not_contains() {
  if [[ $2 != *"$3"* ]]; then
    pass "$1"
  else
    fail "$1" "did not expect: $3"
  fi
}

assert_eq() {
  if [[ $2 == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected '$3', got '$2'"
  fi
}

# strip_noncode <file>
# Reduce a script to the lines that could actually execute something, so the
# read-only scan below can look for dangerous verbs in command position.
#
# Drops comments, and drops the ARGUMENTS of output builtins only - 10-recon.sh
# exists to talk about flashing and unlocking, so those words appear
# legitimately inside printf/echo text. Everything else keeps its quotes: an
# earlier version stripped ALL quoted strings, which let
# `mtk_adb shell "reboot bootloader"` slip through the scan entirely.
strip_noncode() {
  sed -E \
    -e 's/(^|[[:space:]])#.*$/\1/' \
    -e 's/^[[:space:]]*(printf|echo|cat)[[:space:]].*$//' \
    -e 's/\|[[:space:]]*(printf|echo|cat)[[:space:]].*$//' \
    "$1"
}

# run_recon <fixture-name> [extra args...] - prints combined output.
run_recon() {
  local fixture="$1"
  shift
  MTK_ROOT_FIXTURE="$FIXTURES/$fixture" \
    MTK_ROOT_CACHE="$WORKROOT/cache" \
    MTK_SERIAL="TEST$RANDOM" \
    "$RECON" "$@" 2>&1
}
