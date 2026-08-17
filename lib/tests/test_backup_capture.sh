#!/usr/bin/env bash
# Unit tests for lib/backup_capture.sh against the fake device in
# backup_capture_harness.sh. No real phone is needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=backup_capture_harness.sh
. "${SCRIPT_DIR}/backup_capture_harness.sh"

# --- dump_packages ----------------------------------------------------------

dump_packages "${OUT}"

_t_eq "3" "$(wc -l <"${OUT}/packages-all.txt")" "dump_packages records every package"
_t_eq "2" "$(wc -l <"${OUT}/packages-third-party.txt")" "dump_packages separates third-party packages"

case "$(cat "${OUT}/packages-all.txt")" in
    *package:*) _t_fail "dump_packages left the package: prefix in place" ;;
    *) _t_pass "dump_packages strips the package: prefix" ;;
esac

_t_eq "com.purged.app" "$(cat "${OUT}/packages-removed-for-user0.txt")" \
    "dump_packages derives the packages purged for user 0"

# A carriage return surviving into the list would break every later grep.
if grep -q $'\r' "${OUT}/packages-all.txt"; then
    _t_fail "dump_packages left carriage returns in the package list"
else
    _t_pass "dump_packages strips carriage returns"
fi

# --- pull_apks --------------------------------------------------------------

pull_apks "${OUT}"

# Both packages, not just the first: the mapfile-before-loop fix in pull_apks
# exists because adb inside a `while read < file` loop drains the same stdin
# and it pulled 1 of 54.
_t_eq "2" "$(find "${OUT}/apks" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
    "pull_apks visits every third-party package"
_t_eq "3" "$(find "${OUT}/apks" -name '*.apk' | wc -l)" \
    "pull_apks pulls each split of a split app"
_t_eq "2" "$(find "${OUT}/apks/com.example.one" -name '*.apk' | wc -l)" \
    "pull_apks keeps a split app's parts together"

# A package with no resolvable path is warned about, not fatal.
printf 'com.example.one\ncom.example.two\ncom.no.path\n' >"${OUT}/packages-third-party.txt"
rm -rf "${OUT}/apks"
pull_apks "${OUT}"
if grep -q "no APK path for com.no.path" "${DEV}/warnings"; then
    _t_pass "pull_apks warns when a package has no APK path"
else
    _t_fail "pull_apks should warn about a package with no APK path"
fi

# A failing pull is warned about and does not abort the run.
: >"${DEV}/warnings"
touch "${DEV}/fail_pull"
rm -rf "${OUT}/apks"
pull_apks "${OUT}"
if grep -q "could not pull base.apk" "${DEV}/warnings"; then
    _t_pass "pull_apks warns on a failed pull without aborting"
else
    _t_fail "pull_apks should warn on a failed pull"
fi
rm -f "${DEV}/fail_pull"

# --- pull_sdcard ------------------------------------------------------------

: >"${DEV}/pulled"
: >"${DEV}/warnings"
pull_sdcard "${OUT}"

_t_eq "8" "$(grep -c '^/sdcard/' "${DEV}/pulled")" \
    "pull_sdcard pulls every directory in SDCARD_DIRS"

# A directory that is absent on the device is skipped silently.
: >"${DEV}/pulled"
touch "${DEV}/nodir_Signal" "${DEV}/nodir_RunnerUp"
pull_sdcard "${OUT}"
_t_eq "6" "$(grep -c '^/sdcard/' "${DEV}/pulled")" \
    "pull_sdcard skips directories the device does not have"
rm -f "${DEV}/nodir_Signal" "${DEV}/nodir_RunnerUp"

# KeePass databases are found anywhere under /sdcard and pulled aside.
: >"${DEV}/pulled"
printf '/sdcard/Documents/vault.kdbx\n/sdcard/keys/other.kdbx\n' >"${DEV}/kdbx"
pull_sdcard "${OUT}"
_t_eq "2" "$(grep -c '\.kdbx$' "${DEV}/pulled")" "pull_sdcard pulls every KeePass database"

# The destination must exist before the pull, not as a side effect of it: a
# real `adb pull` into a missing directory fails rather than creating it.
# Asserting on the directory afterwards would pass even with the mkdir gone,
# because the mock creates it too — so the check runs with pulls failing.
: >"${DEV}/pulled"
rm -rf "${OUT}/sdcard/keepass"
touch "${DEV}/fail_pull"
pull_sdcard "${OUT}"
rm -f "${DEV}/fail_pull"
if [[ -d "${OUT}/sdcard/keepass" ]]; then
    _t_pass "pull_sdcard creates the keepass directory before pulling into it"
else
    _t_fail "pull_sdcard should create the keepass directory itself"
fi

# A failed sdcard pull warns rather than aborting.
: >"${DEV}/warnings"
: >"${DEV}/kdbx"
touch "${DEV}/fail_pull"
pull_sdcard "${OUT}"
if grep -q "partial or failed pull" "${DEV}/warnings"; then
    _t_pass "pull_sdcard warns on a partial pull without aborting"
else
    _t_fail "pull_sdcard should warn on a failed directory pull"
fi
rm -f "${DEV}/fail_pull"

# --- dump_settings ----------------------------------------------------------

dump_settings "${OUT}"

for ns in system secure global; do
    if [[ -s "${OUT}/settings-${ns}.txt" ]]; then
        _t_pass "dump_settings captures the ${ns} namespace"
    else
        _t_fail "dump_settings did not capture ${ns}"
    fi
done

if grep -q $'\r' "${OUT}/settings-system.txt"; then
    _t_fail "dump_settings left carriage returns in the settings dump"
else
    _t_pass "dump_settings strips carriage returns"
fi

# --- dump_focus_state -------------------------------------------------------

dump_focus_state "${OUT}"

if grep -q "com.purged.app" "${OUT}/focus-state.md"; then
    _t_pass "dump_focus_state lists the packages purged for user 0"
else
    _t_fail "dump_focus_state should list the purged packages"
fi

if grep -q "^## RethinkDNS installed: no" "${OUT}/focus-state.md"; then
    _t_pass "dump_focus_state reports RethinkDNS absent when it is not installed"
else
    _t_fail "dump_focus_state should report RethinkDNS as absent"
fi

printf 'com.celzero.bravedns\n' >>"${OUT}/packages-all.txt"
dump_focus_state "${OUT}"
if grep -q "^## RethinkDNS installed: yes" "${OUT}/focus-state.md"; then
    _t_pass "dump_focus_state reports RethinkDNS present when it is installed"
else
    _t_fail "dump_focus_state should report RethinkDNS as present"
fi

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
