#!/usr/bin/env bash
# lib/tests/daemon_cases_apps.sh — assertions for daemon_apps.sh: which
# packages survive the focus-mode sweep, and what happens on the way in and
# out of focus mode.
#
# Sourced by test_daemon_libs.sh after daemon_libs_harness.sh, which owns the
# stubs, the subjects and the PASS/FAIL counters this file adds to.
#
# is_allowed is the single decision that determines whether an app keeps
# working. Everything below is a way of getting it wrong: the wrong list at
# night, a prefix that matches too much, a guard that resurrects a browser
# during curfew, or a default handler that gets disabled and leaves the phone
# without a keyboard after a reboot.
set -euo pipefail

_seed_lists() {
    printf 'com.allowed.day\ncom.both\n' >"${STATE_DIR}/whitelist.txt"
    printf 'com.both\n' >"${STATE_DIR}/night_whitelist.txt"
    printf 'com.android.\n' >"${STATE_DIR}/sysprotect.txt"
    : >"${STATE_DIR}/default_handlers.txt"
    : >"${STATE_DIR}/default_browser.txt"
}

# --- is_allowed, day --------------------------------------------------------

_reset_dev
_seed_lists
NIGHT_CURFEW_ENABLED=0

if is_allowed "com.allowed.day"; then
    _t_pass "a day-whitelisted package is allowed outside curfew"
else
    _t_fail "the day whitelist must apply outside curfew"
fi

if ! is_allowed "com.random.app"; then
    _t_pass "an unlisted package is not allowed"
else
    _t_fail "an unlisted package must not be allowed"
fi

# Exact match on the whitelist. The query has to be a SUBSTRING of a listed
# entry, not a superstring: grep -qF "com.allowed" would match the line
# "com.allowed.day" and let an unlisted package through, while
# "com.allowed.dayplanner" fails under both -qF and -qxF and so proves
# nothing about which is in use.
if ! is_allowed "com.allowed"; then
    _t_pass "whitelist matching is exact, not by substring"
else
    _t_fail "a substring of a whitelist entry must not be allowed"
fi
if ! is_allowed "com.allowed.dayplanner"; then
    _t_pass "a superstring of a whitelist entry is not allowed"
else
    _t_fail "a superstring of a whitelist entry must not be allowed"
fi

# The sysprotect list IS a prefix list, deliberately, so a whole namespace
# stays reachable.
if is_allowed "com.android.settings"; then
    _t_pass "the sysprotect list matches by prefix"
else
    _t_fail "sysprotect must match by prefix"
fi

# Anchored at the START, not matched anywhere: "org.evil.com.android.thing"
# contains the protected prefix but is not in that namespace, and an
# unanchored match would silently protect any package that mentions it.
if ! is_allowed "org.evil.com.android.thing"; then
    _t_pass "a sysprotect prefix must match at the start, not anywhere"
else
    _t_fail "a sysprotect prefix must be anchored at the start"
fi
if ! is_allowed "org.android.fake"; then
    _t_pass "a package outside the protected namespace is not protected"
else
    _t_fail "only the protected namespace may match sysprotect"
fi

# The default-handler guard is independent of the whitelist, so a config edit
# can never disable the dialer, SMS app, launcher or keyboard.
printf 'com.dialer.app\n' >"${STATE_DIR}/default_handlers.txt"
if is_allowed "com.dialer.app"; then
    _t_pass "a default handler is allowed even when not whitelisted"
else
    _t_fail "the default-handler guard must override the whitelist"
fi

# The browser guard applies only outside curfew.
printf 'com.browser.app\n' >"${STATE_DIR}/default_browser.txt"
if is_allowed "com.browser.app"; then
    _t_pass "the default browser is allowed outside curfew"
else
    _t_fail "the default browser must be allowed outside curfew"
fi

# --- is_allowed, night curfew ----------------------------------------------

_reset_dev
_seed_lists
printf 'com.browser.app\n' >"${STATE_DIR}/default_browser.txt"
NIGHT_CURFEW_ENABLED=1
_set_now "0000"

# The strict list replaces the permissive one — this is the whole point of the
# curfew, and getting it backwards would leave the night unrestricted.
if is_allowed "com.both"; then
    _t_pass "a night-whitelisted package is allowed during curfew"
else
    _t_fail "the night whitelist must apply during curfew"
fi

if ! is_allowed "com.allowed.day"; then
    _t_pass "a day-only package is blocked during curfew"
else
    _t_fail "the day list must NOT apply during curfew"
fi

# The browser guard must not resurrect a browser at night.
if ! is_allowed "com.browser.app"; then
    _t_pass "the default browser is blocked during curfew"
else
    _t_fail "the browser guard must not re-allow a browser during curfew"
fi

# The sysprotect and default-handler guards still apply on top of the strict
# list, or the curfew could disable the keyboard.
if is_allowed "com.android.settings"; then
    _t_pass "sysprotect still applies during curfew"
else
    _t_fail "sysprotect must apply during curfew too"
fi

printf 'com.ime.app\n' >"${STATE_DIR}/default_handlers.txt"
if is_allowed "com.ime.app"; then
    _t_pass "the default-handler guard still applies during curfew"
else
    _t_fail "the keyboard must stay reachable during curfew"
fi

NIGHT_CURFEW_ENABLED=0
_t_eq "0" "${NIGHT_CURFEW_ENABLED}" \
    "the curfew is switched back off for the sweep cases"
