#!/usr/bin/env bash
# lib/tests/curfew_net_cases_lifecycle.sh — assertions for the lifecycle half
# of curfew_net.sh: iptw, refresh_uid_cache, rebuild_net_from_cache, net_hold,
# apply_net and teardown_net.
#
# Sourced by test_curfew_net.sh after curfew_net_harness.sh, which owns the
# stubs, the subject and the PASS/FAIL counters this file adds to.
set -euo pipefail

# --- iptw -------------------------------------------------------------------

_reset_ipt
iptw iptables -L "${CURFEW_NET_IPT_CHAIN}" >/dev/null 2>&1 || true
if _calls | grep -q "^iptables -L"; then
    _t_pass "iptw dispatches to the named binary"
else
    _t_fail "iptw did not call the named binary"
fi

# --- refresh_uid_cache ------------------------------------------------------

printf 'com.foo\ncom.bar\n' >"${STATE_DIR}/night_whitelist.txt"
printf 'com.foo uid:10123\ncom.bar uid:10456\n' >"${PM_FIXTURE}"
rm -f "${CURFEW_NET_UID_CACHE}"
refresh_uid_cache
_t_eq "10123 10456" "$(tr '\n' ' ' <"${CURFEW_NET_UID_CACHE}" | sed 's/ $//')" \
    "refresh_uid_cache writes the resolved uids"

if [[ ! -f "${CURFEW_NET_UID_CACHE}.tmp" ]]; then
    _t_pass "refresh_uid_cache moves its temp file into place"
else
    _t_fail "refresh_uid_cache left a .tmp file behind"
fi

# --- rebuild_net_from_cache -------------------------------------------------

_reset_ipt
rebuild_net_from_cache
if [[ -n "$(_rules_of iptables)" && -n "$(_rules_of ip6tables)" ]]; then
    _t_pass "rebuild_net_from_cache builds both v4 and v6 chains"
else
    _t_fail "rebuild_net_from_cache should build both address families"
fi

# --- net_hold ---------------------------------------------------------------

# Chain intact for the whole window: no rebuild.
_reset_ipt
_seed_jumps iptables 1
# Read back after assigning: the subject is what consumes these, but each
# file is linted standalone, so an assignment with no reader here is SC2034.
CURFEW_NET_REASSERT_INTERVAL=1
_t_eq "1" "${CURFEW_NET_REASSERT_INTERVAL}" "the reassert interval is set for net_hold"
_t_eq "0" "$(net_hold 2)" "net_hold does not rebuild while the chain survives"

# Chain missing: the first check rebuilds it, and because the rebuild
# actually creates the chain the second check finds it present. One rebuild
# for a single flush is the self-healing behaviour, not a missed one.
_reset_ipt
_t_eq "1" "$(net_hold 2)" "net_hold rebuilds a vanished chain and then settles"

# --- apply_net --------------------------------------------------------------

_reset_ipt
CURFEW_NET_ENABLED=0
apply_net
_t_eq "" "$(_calls)" "apply_net does nothing while the net layer is disabled"
CURFEW_NET_ENABLED=1
_t_eq "1" "${CURFEW_NET_ENABLED}" "the net layer is re-enabled for the remaining cases"

_reset_ipt
NET_BUILT=""
apply_net
_t_eq "1" "${NET_BUILT}" "apply_net marks the chain as built"
if [[ -n "$(_rules_of iptables)" && -n "$(_rules_of ip6tables)" ]]; then
    _t_pass "apply_net builds both address families"
else
    _t_fail "apply_net should build both address families"
fi

# A chain that vanished between ticks is logged, so a live test can tell
# "external flush + self-heal" from "the daemon died".
_reset_ipt
: >"${STATE_DIR}/log"
NET_BUILT=1
apply_net
if grep -q "vanished since last tick" "${STATE_DIR}/log"; then
    _t_pass "apply_net logs an externally flushed chain"
else
    _t_fail "apply_net should log when the chain vanished between ticks"
fi

# On a first build there is nothing to have vanished, so nothing is logged.
_reset_ipt
: >"${STATE_DIR}/log"
NET_BUILT=""
apply_net
if grep -q "vanished since last tick" "${STATE_DIR}/log"; then
    _t_fail "apply_net logged a vanished chain on its first build"
else
    _t_pass "apply_net stays quiet on the first build"
fi

# --- teardown_net -----------------------------------------------------------

_reset_ipt
_seed_jumps iptables 2
_seed_jumps ip6tables 1
teardown_net

# 2 jumps + 1 terminating failure on v4, 1 + 1 on v6 = 5.
_t_eq "5" "$(_calls | grep -c -- "-D OUTPUT -j FOCUS_CURFEW_NET")" \
    "teardown_net removes every OUTPUT jump on both families"
_t_eq "2" "$(_calls | grep -c -- "-X FOCUS_CURFEW_NET")" \
    "teardown_net deletes the chain on both families"

if [[ -f "${RUN}/ipt/iptables/chain" ]]; then
    _t_fail "teardown_net left the v4 chain in place"
else
    _t_pass "teardown_net leaves no chain behind"
fi
