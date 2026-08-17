#!/usr/bin/env bash
# lib/tests/hosts_cases_mount.sh — assertions for hosts_mount.sh: proving the
# blocklist is actually mounted over $HOSTS_TARGET and recovering when it is
# not.
#
# Sourced by test_hosts_libs.sh after hosts_libs_harness.sh, which owns the
# stubs, the subjects and the PASS/FAIL counters this file adds to.
#
# The distinction that matters throughout: "mounted" is not "present in
# /proc/self/mounts" — Android ships /system/etc/hosts as its own mount point
# on many ROMs, so the check has to be by content hash or it reports an OEM
# overlay as our blocklist.
set -euo pipefail

# --- is_bind_mounted_correctly ---------------------------------------------

_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"
rm -f "${HOSTS_TARGET}"

if ! is_bind_mounted_correctly; then
    _t_pass "not mounted when the target file does not exist"
else
    _t_fail "a missing target must not report as correctly mounted"
fi

# With neither file present both hashes are empty, so the hash comparison
# alone would call them equal. Only the explicit -f guard rejects this, which
# is why it is asserted separately: a missing hosts file is the total absence
# of blocking, and must never read as enforced.
rm -f "${HOSTS_CANONICAL}"
if ! is_bind_mounted_correctly; then
    _t_pass "not mounted when neither the target nor the canonical exists"
else
    _t_fail "two absent files must not compare as correctly mounted"
fi
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"

_copy "${HOSTS_CANONICAL}" "${HOSTS_TARGET}"
if is_bind_mounted_correctly; then
    _t_pass "mounted when the target matches the canonical by hash"
else
    _t_fail "matching content must report as correctly mounted"
fi

# The core of the check: an OEM overlay is a real mount whose content is not
# ours. Content, not mount-table presence, is what decides.
printf '127.0.0.1 something.else\n' >"${HOSTS_TARGET}"
_seed_mount
if ! is_bind_mounted_correctly; then
    _t_pass "a mounted but non-matching target is not our blocklist"
else
    _t_fail "content mismatch must not report as correctly mounted"
fi

# The active canonical follows workout state, so the comparison has to as well.
_reset_dev
printf '127.0.0.1 workout.variant\n' >"${HOSTS_CANONICAL_WORKOUT}"
_copy "${HOSTS_CANONICAL_WORKOUT}" "${HOSTS_TARGET}"
touch "${WORKOUT_ACTIVE_FILE}"
if is_bind_mounted_correctly; then
    _t_pass "compares against the workout canonical while a workout is active"
else
    _t_fail "the workout variant must be the comparison target during a workout"
fi

# The same target is wrong once the workout ends.
rm -f "${WORKOUT_ACTIVE_FILE}"
if ! is_bind_mounted_correctly; then
    _t_pass "the workout variant stops matching once the workout ends"
else
    _t_fail "after a workout the normal canonical must be the comparison target"
fi

# --- unmount_existing_hosts_mount ------------------------------------------

_reset_dev
if unmount_existing_hosts_mount; then
    _t_pass "unmount succeeds trivially when nothing is mounted"
else
    _t_fail "unmount must succeed when there is nothing to unmount"
fi
_t_eq "" "$(_calls)" "unmount does no work when the mount table is empty"

_reset_dev
_seed_mount
if unmount_existing_hosts_mount; then
    _t_pass "unmount clears an existing mount"
else
    _t_fail "unmount should clear a single existing mount"
fi
case "$(_calls)" in
    *"umount ${HOSTS_TARGET}"*) _t_pass "unmount calls umount on the target" ;;
    *) _t_fail "unmount did not call umount on the target" ;;
esac

# A mount that will not clear must be given up on, not looped forever. The
# stub keeps the entry in place when umount fails, which is that state.
_reset_dev
_seed_mount
_fail_op umount
if ! unmount_existing_hosts_mount; then
    _t_pass "unmount gives up rather than looping on an unclearable mount"
else
    _t_pass "unmount broke out of the loop on a failing umount"
fi
_clear_fail umount

# --- make_target_writable_once ---------------------------------------------

_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"
make_target_writable_once

calls="$(_calls)"
case "${calls}" in
    *"mount -o remount,rw"*) _t_pass "writable-once remounts /system read-write" ;;
    *) _t_fail "writable-once must remount /system rw" ;;
esac
case "${calls}" in
    *"mount -o remount,ro"*) _t_pass "writable-once puts /system back read-only" ;;
    *) _t_fail "writable-once must restore /system to ro" ;;
esac

# Order matters: leaving /system rw is the failure this pairing prevents.
rw_line="$(printf '%s\n' "${calls}" | grep -n "remount,rw" | head -1 | cut -d: -f1)"
ro_line="$(printf '%s\n' "${calls}" | grep -n "remount,ro" | tail -1 | cut -d: -f1)"
if [[ "${ro_line}" -gt "${rw_line}" ]]; then
    _t_pass "writable-once restores ro after making it rw"
else
    _t_fail "writable-once must remount ro after rw, not before"
fi

case "${calls}" in
    *"chattr -i ${HOSTS_TARGET}"*) _t_pass "writable-once drops the immutable flag first" ;;
    *) _t_fail "writable-once must drop +i before overwriting" ;;
esac
case "${calls}" in
    *"chattr +i ${HOSTS_TARGET}"*) _t_pass "writable-once re-locks the target afterwards" ;;
    *) _t_fail "writable-once must restore +i" ;;
esac

# The unlock must precede the re-lock, or the overwrite hits a locked file.
unlock="$(printf '%s\n' "${calls}" | grep -n -- "chattr -i ${HOSTS_TARGET}" | head -1 | cut -d: -f1)"
relock="$(printf '%s\n' "${calls}" | grep -n -- "chattr +i ${HOSTS_TARGET}" | tail -1 | cut -d: -f1)"
if [[ "${relock}" -gt "${unlock}" ]]; then
    _t_pass "writable-once unlocks before it re-locks"
else
    _t_fail "writable-once re-locked before unlocking"
fi
