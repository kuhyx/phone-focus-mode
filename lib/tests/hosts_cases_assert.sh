#!/usr/bin/env bash
# lib/tests/hosts_cases_assert.sh — assertions for assert_bind_mount, the
# recovery path of hosts_mount.sh: bind the canonical over a wrong target,
# and fall back to a direct overwrite when the bind will not take.
#
# Sourced by test_hosts_libs.sh after hosts_cases_mount.sh, which owns the
# stubs and counters. Split out to stay under the 250-line cap.
set -euo pipefail

# --- assert_bind_mount ------------------------------------------------------

# Already correct: nothing should be mounted or unmounted at all.
_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"
_copy "${HOSTS_CANONICAL}" "${HOSTS_TARGET}"
if assert_bind_mount; then
    _t_pass "assert succeeds without work when already mounted"
else
    _t_fail "assert should succeed when the target already matches"
fi
if _calls | grep -q "^mount --bind"; then
    _t_fail "assert re-mounted a target that was already correct"
else
    _t_pass "assert does not re-mount an already-correct target"
fi

# Wrong content: the bind mount is what fixes it.
_reset_dev
printf '127.0.0.1 tampered\n' >"${HOSTS_TARGET}"
if assert_bind_mount; then
    _t_pass "assert bind-mounts the canonical over a tampered target"
else
    _t_fail "assert should recover a tampered target via bind mount"
fi
case "$(_log)" in
    *"Bind-mounted"*) _t_pass "assert logs the successful bind mount" ;;
    *) _t_fail "assert should log a successful bind mount" ;;
esac

# Bind reports success but changes nothing — the case the code explicitly
# guards, since a silent no-op mount would otherwise read as enforced.
_reset_dev
printf '127.0.0.1 tampered\n' >"${HOSTS_TARGET}"
touch "${DEV}/bind_is_noop"
assert_bind_mount || true
case "$(_log)" in
    *"still mismatches"*) _t_pass "assert detects a bind mount that silently did nothing" ;;
    *) _t_fail "assert must notice a no-op bind mount" ;;
esac
case "$(_log)" in
    *"falling back to direct overwrite"*) _t_pass "assert falls back to direct overwrite" ;;
    *) _t_fail "assert should fall back when the bind does not take" ;;
esac
rm -f "${DEV}/bind_is_noop"

# Bind fails outright: the fallback path has to run and succeed.
_reset_dev
printf '127.0.0.1 tampered\n' >"${HOSTS_TARGET}"
_fail_op mount
assert_bind_mount || true
case "$(_log)" in
    *"Bind mount failed"*) _t_pass "assert logs an outright bind-mount failure" ;;
    *) _t_fail "assert should log when the bind mount fails" ;;
esac
_clear_fail mount

# Nothing works: assert must report failure rather than claim enforcement.
_reset_dev
printf '127.0.0.1 tampered\n' >"${HOSTS_TARGET}"
touch "${DEV}/bind_is_noop"
_fail_op cp
if ! assert_bind_mount; then
    _t_pass "assert fails when neither bind nor overwrite can fix the target"
else
    _t_fail "assert must not report success when the target is still wrong"
fi
_clear_fail cp
rm -f "${DEV}/bind_is_noop"

# A mount that survives five umount attempts must be reported as unclearable,
# not retried forever. The stub is made to "succeed" while leaving the entry
# in place, which is exactly a mount that will not go away.
_reset_dev
_seed_mount
touch "${DEV}/umount_is_noop"
if ! unmount_existing_hosts_mount; then
    _t_pass "unmount reports failure after five attempts"
else
    _t_fail "unmount must fail once it has given up"
fi
case "$(_log)" in
    *"after 5 attempts"*) _t_pass "unmount logs that it gave up" ;;
    *) _t_fail "unmount should log giving up" ;;
esac
# The count is asserted, not just the give-up: a larger threshold would spin
# that many times against a mount that is never going to clear, inside the
# enforcer's poll loop.
_t_eq "5" "$(_calls | grep -c "^umount ")" "unmount tries exactly five times before giving up"
rm -f "${DEV}/umount_is_noop"

# The direct-overwrite fallback succeeding is the last line of defence: the
# bind failed, but the target ends up correct anyway.
_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"
printf '127.0.0.1 tampered\n' >"${HOSTS_TARGET}"
_fail_op mount
touch "${DEV}/overwrite_works"
if assert_bind_mount; then
    _t_pass "assert succeeds via the direct-overwrite fallback"
else
    _t_fail "assert should succeed when the overwrite fixes the target"
fi
rm -f "${DEV}/overwrite_works"
_clear_fail mount
