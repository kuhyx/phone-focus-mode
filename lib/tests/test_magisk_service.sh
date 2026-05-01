#!/usr/bin/env bash
# Unit tests for magisk_service.sh boot safety helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

_t_pass() {
    PASS=$((PASS + 1))
    printf '  OK: %s\n' "$1"
}

_t_fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "$1"
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat >"${TMPDIR_TEST}/config.sh" <<EOF
#!/system/bin/sh
export FOCUS_BOOT_AUTOSTART=0
export LAUNCHER_BOOT_AUTOSTART=0
export FOCUS_BOOT_DELAY_SECONDS=10
export FOCUS_BOOT_EMERGENCY_DISABLE_FILE="${TMPDIR_TEST}/disable_boot_autostart"
export LAUNCHER_APK="${TMPDIR_TEST}/minimalist_launcher.apk"
export LAUNCHER_ACTIVITY_FILE="${TMPDIR_TEST}/minimalist_launcher.activity"
EOF

export FOCUS_MODE_MAGISK_SERVICE_TESTING=1
export FOCUS_MODE_SCRIPT_DIR="${TMPDIR_TEST}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../magisk_service.sh"

if boot_config_ready; then
    _t_pass "boot config is ready when config.sh exists"
else
    _t_fail "boot config should be ready when config.sh exists"
fi

if ! should_start_launcher_enforcer; then
    _t_pass "launcher boot autostart defaults to disabled"
else
    _t_fail "launcher boot autostart should be disabled by default"
fi

if ! should_start_boot_stack; then
    _t_pass "global boot autostart defaults to disabled"
else
    _t_fail "global boot autostart should default to disabled"
fi

if [ "$(boot_delay_seconds)" = "10" ]; then
    _t_pass "boot delay defaults to 10 seconds"
else
    _t_fail "boot delay should default to 10 seconds"
fi

if ! boot_emergency_disabled; then
    _t_pass "boot emergency disable defaults to off"
else
    _t_fail "boot emergency disable should be off when marker missing"
fi

touch "${TMPDIR_TEST}/disable_boot_autostart"
if boot_emergency_disabled; then
    _t_pass "boot emergency disable activates when marker file exists"
else
    _t_fail "boot emergency disable should activate with marker file"
fi
rm -f "${TMPDIR_TEST}/disable_boot_autostart"

mv "${TMPDIR_TEST}/config.sh" "${TMPDIR_TEST}/config.sh.bak"
if ! boot_config_ready; then
    _t_pass "boot config is not ready when config.sh is missing"
else
    _t_fail "boot config should be missing when config.sh is absent"
fi
mv "${TMPDIR_TEST}/config.sh.bak" "${TMPDIR_TEST}/config.sh"

printf 'apk' >"${TMPDIR_TEST}/minimalist_launcher.apk"
printf 'pkg/.Activity' >"${TMPDIR_TEST}/minimalist_launcher.activity"
cat >"${TMPDIR_TEST}/config.sh" <<EOF
#!/system/bin/sh
export FOCUS_BOOT_AUTOSTART=1
export LAUNCHER_BOOT_AUTOSTART=1
export FOCUS_BOOT_DELAY_SECONDS=999
export FOCUS_BOOT_EMERGENCY_DISABLE_FILE="${TMPDIR_TEST}/disable_boot_autostart"
export LAUNCHER_APK="${TMPDIR_TEST}/minimalist_launcher.apk"
export LAUNCHER_ACTIVITY_FILE="${TMPDIR_TEST}/minimalist_launcher.activity"
EOF

if should_start_boot_stack; then
    _t_pass "global boot autostart can be explicitly enabled"
else
    _t_fail "global boot autostart should enable when configured"
fi

if [ "$(boot_delay_seconds)" = "10" ]; then
    _t_pass "boot delay is capped at 10 seconds"
else
    _t_fail "boot delay should clamp to 10 seconds"
fi

if should_start_launcher_enforcer; then
    _t_pass "launcher boot autostart enables only with snapshot artifacts present"
else
    _t_fail "launcher boot autostart should enable when explicitly armed with artifacts"
fi

rm -f "${TMPDIR_TEST}/minimalist_launcher.activity"
if ! should_start_launcher_enforcer; then
    _t_pass "launcher boot autostart stays off when activity snapshot is missing"
else
    _t_fail "launcher boot autostart should refuse missing activity snapshot"
fi

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
