#!/usr/bin/env bash
# lib/tests/hosts_cases_cache.sh — assertions for the cache-invalidation half
# of hosts_magisk.sh: force-stopping browsers so their in-process DNS caches
# clear, holding the canonical files immutable, and restarting netd so its
# in-memory copy of the hosts file is reloaded.
#
# Sourced by test_hosts_libs.sh after hosts_cases_magisk.sh, which owns the
# stubs and counters. Split out to stay under the 250-line cap.
set -euo pipefail

# --- flush_browser_dns_caches ----------------------------------------------

_reset_dev
flush_browser_dns_caches
calls="$(_calls)"
for pkg in org.mozilla.fenix com.android.chrome; do
    case "${calls}" in
        *"am force-stop ${pkg}"*) _t_pass "flush force-stops ${pkg}" ;;
        *) _t_fail "flush must force-stop ${pkg}" ;;
    esac
done
case "$(_log)" in
    *"Flushed DNS cache"*) _t_pass "flush logs each browser it stopped" ;;
    *) _t_fail "flush should log the browsers it stopped" ;;
esac

# A browser that is not running must not be reported as flushed.
_reset_dev
_fail_op am
flush_browser_dns_caches
if _log | grep -q "Flushed DNS cache"; then
    _t_fail "flush claimed to stop a browser that was not running"
else
    _t_pass "flush stays quiet when no browser was running"
fi
_clear_fail am

# --- ensure_canonical_immutable --------------------------------------------

_reset_dev
printf '127.0.0.1 blocked.example\n' >"${HOSTS_CANONICAL}"
rm -f "${HOSTS_CANONICAL_WORKOUT}"
ensure_canonical_immutable
case "$(_calls)" in
    *"chattr +i ${HOSTS_CANONICAL}"*) _t_pass "immutable locks the active canonical" ;;
    *) _t_fail "immutable must lock the canonical" ;;
esac
if _calls | grep -qF "chattr +i ${HOSTS_CANONICAL_WORKOUT}"; then
    _t_fail "immutable locked a workout canonical that does not exist"
else
    _t_pass "immutable skips a workout canonical that is absent"
fi

# Both variants are locked when both exist, so a later workout transition is
# just as tamper-resistant as the current state.
_reset_dev
printf '127.0.0.1 workout\n' >"${HOSTS_CANONICAL_WORKOUT}"
ensure_canonical_immutable
case "$(_calls)" in
    *"chattr +i ${HOSTS_CANONICAL_WORKOUT}"*) _t_pass "immutable locks the workout canonical too" ;;
    *) _t_fail "immutable must lock both canonical variants" ;;
esac

# --- restart_netd_for_hosts_cache ------------------------------------------

# netd not running: nothing to restart, and no stamp written.
_reset_dev
rm -f "${STATE_DIR}/netd_restart.pid"
restart_netd_for_hosts_cache
if [[ -f "${STATE_DIR}/netd_restart.pid" ]]; then
    _t_fail "netd restart stamped a pid when netd was not running"
else
    _t_pass "netd restart does nothing when netd is not running"
fi

# Same pid as last time: already restarted this boot, so skip the network
# blip. This is the check that keeps an enforcer restart from cycling netd.
_reset_dev
printf '4242\n' >"${DEV}/netd_pid"
printf '4242\n' >"${STATE_DIR}/netd_restart.pid"
restart_netd_for_hosts_cache
if _calls | grep -q "^stop netd"; then
    _t_fail "netd was restarted again for a pid already stamped"
else
    _t_pass "netd restart is skipped when the pid is unchanged"
fi

# A real Firefox profile (one containing prefs.js) gets the DoH-disable pref.
# Firefox reaches its DoH resolver over hardcoded bootstrap IPs, so the hosts
# file alone does not stop it — this pref is what does.
_reset_dev
real_profile="${FENIX_DIR}/abc123.default/"
mkdir -p "${real_profile}"
printf 'user_pref("x", 1);\n' >"${real_profile}prefs.js"
disable_firefox_doh
if grep -qF 'user_pref("network.trr.mode", 5);' "${real_profile}user.js" 2>/dev/null; then
    _t_pass "firefox DoH writes the trr.mode pref to a real profile"
else
    _t_fail "firefox DoH must write the trr.mode pref"
fi
case "$(_log)" in
    *"Wrote DoH-disable pref"*) _t_pass "firefox DoH logs the profile it wrote" ;;
    *) _t_fail "firefox DoH should log the write" ;;
esac

# Already present: the pref must not be appended twice on every flush.
_reset_dev
disable_firefox_doh
_t_eq "1" "$(grep -cF 'network.trr.mode' "${real_profile}user.js")" \
    "firefox DoH does not duplicate an existing pref"
if _log | grep -q "Wrote DoH-disable pref"; then
    _t_fail "firefox DoH logged a write it did not perform"
else
    _t_pass "firefox DoH stays quiet when the pref is already set"
fi

# --- restart_netd_for_hosts_cache, the restart path -------------------------

# A different pid than last stamped means netd has been cycled since our last
# restart, so the hosts cache is stale again and must be reloaded.
_reset_dev
printf '5555\n' >"${DEV}/netd_pid"
printf '1111\n' >"${STATE_DIR}/netd_restart.pid"
restart_netd_for_hosts_cache

calls="$(_calls)"
case "${calls}" in
    *"stop netd"*) _t_pass "netd restart stops netd when the pid changed" ;;
    *) _t_fail "netd restart must stop netd on a changed pid" ;;
esac
case "${calls}" in
    *"start netd"*) _t_pass "netd restart starts netd again" ;;
    *) _t_fail "netd restart must start netd again" ;;
esac

stop_line="$(printf '%s\n' "${calls}" | grep -n "^stop netd" | head -1 | cut -d: -f1)"
start_line="$(printf '%s\n' "${calls}" | grep -n "^start netd" | head -1 | cut -d: -f1)"
if [[ "${start_line}" -gt "${stop_line}" ]]; then
    _t_pass "netd restart starts only after it has stopped"
else
    _t_fail "netd restart must stop before it starts"
fi

_t_eq "5555" "$(cat "${STATE_DIR}/netd_restart.pid")" \
    "netd restart stamps the new pid so the next tick skips the work"
case "$(_log)" in
    *"hosts cache is now live"*) _t_pass "netd restart logs completion" ;;
    *) _t_fail "netd restart should log completion" ;;
esac
