#!/usr/bin/env bash
# lib/tests/hosts_cases_magisk.sh — assertions for hosts_magisk.sh: keeping
# the Magisk module in step, defeating the module's disable/remove markers,
# and making already-running resolvers notice a changed hosts file.
#
# Sourced by test_hosts_libs.sh after hosts_libs_harness.sh, which owns the
# stubs, the subjects and the PASS/FAIL counters this file adds to.
set -euo pipefail

readonly MODULE_DIR="${RUN}/state/modules/hosts"

_seed_module() {
    rm -rf "${MODULE_DIR}"
    mkdir -p "${MODULE_DIR}/system/etc"
    printf '%s' "${1:-}" >"${HOSTS_MAGISK_MODULE_FILE}"
}

# --- sync_magisk_module -----------------------------------------------------

_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"

_seed_module "old content"
sync_magisk_module ""
_t_eq "" "$(_calls)" "sync does nothing when handed an empty canonical"

sync_magisk_module "${RUN}/state/no-such-file"
_t_eq "" "$(_calls)" "sync does nothing when the canonical does not exist"

# No module installed: sync must be a no-op, not an error.
_reset_dev
rm -rf "${MODULE_DIR}"
sync_magisk_module "${HOSTS_CANONICAL}"
if _calls | grep -q "^cp "; then
    _t_fail "sync wrote to a module directory that does not exist"
else
    _t_pass "sync is a no-op when the Magisk module is not installed"
fi

# Contents differ: the module gets rewritten, and unlocked to allow it.
_reset_dev
_seed_module "stale"
sync_magisk_module "${HOSTS_CANONICAL}"
calls="$(_calls)"
case "${calls}" in
    *"cp ${HOSTS_CANONICAL} ${HOSTS_MAGISK_MODULE_FILE}"*)
        _t_pass "sync copies the canonical into the module" ;;
    *) _t_fail "sync must copy the canonical when contents differ" ;;
esac
case "${calls}" in
    *"chattr -i ${HOSTS_MAGISK_MODULE_FILE}"*)
        _t_pass "sync drops the file's immutable flag before writing" ;;
    *) _t_fail "sync must unlock the module file before writing" ;;
esac
case "$(_log)" in
    *"Synced Magisk module hosts"*) _t_pass "sync logs the rewrite" ;;
    *) _t_fail "sync should log when it rewrites the module" ;;
esac

# Already in step: the cheap hash compare must skip the write entirely, which
# is what keeps this off the hot path of every poll iteration.
_reset_dev
_seed_module ""
_copy "${HOSTS_CANONICAL}" "${HOSTS_MAGISK_MODULE_FILE}"
sync_magisk_module "${HOSTS_CANONICAL}"
if _calls | grep -q "^cp "; then
    _t_fail "sync rewrote a module that was already in step"
else
    _t_pass "sync skips the write when the hashes already match"
fi

# Even when it skips the write, the directory lock is re-asserted.
case "$(_calls)" in
    *"chattr +i ${MODULE_DIR}"*) _t_pass "sync re-locks the module directory regardless" ;;
    *) _t_fail "sync must re-assert the directory lock every time" ;;
esac

# --- protect_magisk_module --------------------------------------------------

_reset_dev
rm -rf "${MODULE_DIR}"
protect_magisk_module || true
_t_eq "" "$(_calls)" "protect does nothing when the module is not installed"

# No markers present: the dir is still locked, nothing is reported removed.
_reset_dev
_seed_module ""
protect_magisk_module
_t_eq "0" "$?" "protect reports no markers removed on a clean module"
case "$(_calls)" in
    *"chattr +i ${MODULE_DIR}"*) _t_pass "protect locks the module directory" ;;
    *) _t_fail "protect must lock the module directory" ;;
esac

# Each of the three markers is a separate way to disable the module through
# the Magisk UI, so each must be removed.
for marker in disable remove update; do
    _reset_dev
    _seed_module ""
    touch "${MODULE_DIR}/${marker}"
    protect_magisk_module && rc=0 || rc=$?
    _t_eq "1" "${rc}" "protect reports removing the '${marker}' marker"
    if [[ -e "${MODULE_DIR}/${marker}" ]]; then
        _t_fail "protect left the '${marker}' marker in place"
    else
        _t_pass "protect deletes the '${marker}' marker"
    fi
    case "$(_log)" in
        *"TAMPER: removed Magisk module marker"*) _t_pass "protect logs the '${marker}' tamper" ;;
        *) _t_fail "protect must log the '${marker}' tamper" ;;
    esac
done

# All three at once, so the count is a count and not a boolean.
_reset_dev
_seed_module ""
touch "${MODULE_DIR}/disable" "${MODULE_DIR}/remove" "${MODULE_DIR}/update"
protect_magisk_module && rc=0 || rc=$?
_t_eq "3" "${rc}" "protect counts every marker it removed"

# --- disable_firefox_doh ----------------------------------------------------

_reset_dev
rm -rf "${FENIX_DIR:?}"/*
mkdir -p "${FENIX_DIR}/not-a-profile"

# A directory with no prefs.js is not a real profile and must be skipped.
disable_firefox_doh
_t_eq "" "$(_log)" "firefox DoH skips directories that are not profiles"
