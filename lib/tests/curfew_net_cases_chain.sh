#!/usr/bin/env bash
# lib/tests/curfew_net_cases_chain.sh — assertions for the chain-construction
# half of curfew_net.sh: night_uids, ensure_net_chain and fill_net_chain.
#
# Sourced by test_curfew_net.sh after curfew_net_harness.sh, which owns the
# stubs, the subject and the PASS/FAIL counters this file adds to. Split out
# to keep every test file under the repo's 250-line cap.
set -euo pipefail

# --- night_uids -------------------------------------------------------------

_t_eq "" "$(night_uids)" "night_uids is empty when the whitelist file is absent"

printf 'com.foo\ncom.bar\n\ncom.absent\n' >"${STATE_DIR}/night_whitelist.txt"
printf 'com.foo uid:10123\ncom.bar uid:10456\ncom.other uid:10999\n' >"${PM_FIXTURE}"

_t_eq "10123 10456" "$(night_uids | tr '\n' ' ' | sed 's/ $//')" \
    "night_uids resolves only the whitelisted packages"

if [[ ! -f "${STATE_DIR}/uid_map.txt" ]]; then
    _t_pass "night_uids cleans up its temporary uid map"
else
    _t_fail "night_uids left uid_map.txt behind"
fi

# --- ensure_net_chain -------------------------------------------------------

_reset_ipt
if ensure_net_chain iptables; then
    _t_pass "ensure_net_chain creates a missing chain"
else
    _t_fail "ensure_net_chain should succeed when it can create the chain"
fi

case "$(_calls)" in
    *"-N FOCUS_CURFEW_NET"*) _t_pass "ensure_net_chain creates the named chain" ;;
    *) _t_fail "ensure_net_chain did not create the chain" ;;
esac

case "$(_calls)" in
    *"-I OUTPUT 1 -j FOCUS_CURFEW_NET"*) _t_pass "ensure_net_chain pins the OUTPUT jump at position 1" ;;
    *) _t_fail "ensure_net_chain did not pin the jump at position 1" ;;
esac

# Chain creation failing must be reported, not silently continued past.
_reset_ipt
_fail_op N
if ! ensure_net_chain iptables; then
    _t_pass "ensure_net_chain fails when the chain cannot be created"
else
    _t_fail "ensure_net_chain should fail when -N fails"
fi
_clear_fail N

# The jump insert failing likewise.
_reset_ipt
_fail_op I
if ! ensure_net_chain iptables; then
    _t_pass "ensure_net_chain fails when the OUTPUT jump cannot be inserted"
else
    _t_fail "ensure_net_chain should fail when -I fails"
fi
_clear_fail I

# Stale duplicate jumps left by a lock race are removed before the new one.
_reset_ipt
_seed_jumps iptables 3
ensure_net_chain iptables
# Four calls for three jumps: the loop is `while -D succeeds`, so the fourth
# is the one that fails and ends it. Asserting on the count rather than on
# the final state is what would catch the loop terminating early.
_t_eq "4" "$(_calls | grep -c -- "-D OUTPUT -j FOCUS_CURFEW_NET")" \
    "ensure_net_chain deletes every stale OUTPUT jump"
_t_eq "1" "$(cat "${RUN}/ipt/iptables/jumps")" \
    "ensure_net_chain leaves exactly one OUTPUT jump"

# An existing chain is reused rather than recreated.
_reset_ipt
_seed_jumps iptables 0
ensure_net_chain iptables
if _calls | grep -q -- "-N FOCUS_CURFEW_NET"; then
    _t_fail "ensure_net_chain recreated a chain that already existed"
else
    _t_pass "ensure_net_chain reuses an existing chain"
fi

# --- fill_net_chain ---------------------------------------------------------

_reset_ipt
printf '10123\n10456\n' >"${CURFEW_NET_UID_CACHE}"
fill_net_chain iptables icmp-port-unreachable

rules="$(_rules_of iptables)"

case "${rules}" in
    *"-o lo -j ACCEPT"*) _t_pass "fill_net_chain always allows loopback" ;;
    *) _t_fail "fill_net_chain must allow loopback" ;;
esac

case "${rules}" in
    *"ESTABLISHED,RELATED -j ACCEPT"*) _t_pass "fill_net_chain allows established flows" ;;
    *) _t_fail "fill_net_chain must allow established flows" ;;
esac

for uid in 0 1000 2000; do
    case "${rules}" in
        *"--uid-owner ${uid} -j ACCEPT"*) _t_pass "fill_net_chain allows uid ${uid}" ;;
        *) _t_fail "fill_net_chain must allow uid ${uid}" ;;
    esac
done

# DNS on both protocols: apps resolve via netd under a different uid, so
# without these every lookup fails under the cut-off.
_t_eq "2" "$(printf '%s\n' "${rules}" | grep -c -- "--dport 53 -j ACCEPT")" \
    "fill_net_chain allows DNS over both udp and tcp"

for uid in 10123 10456; do
    case "${rules}" in
        *"--uid-owner ${uid} -j ACCEPT"*) _t_pass "fill_net_chain allows whitelisted uid ${uid}" ;;
        *) _t_fail "fill_net_chain must allow whitelisted uid ${uid}" ;;
    esac
done

case "${rules}" in
    *"--uid-owner 10000-19999 -j REJECT"*) _t_pass "fill_net_chain rejects the remaining app uid range" ;;
    *) _t_fail "fill_net_chain must reject the remaining app range" ;;
esac

# Ordering is the whole point: a REJECT before the ACCEPTs blocks everything.
reject_line="$(printf '%s\n' "${rules}" | grep -n -- "10000-19999" | cut -d: -f1)"
last_accept="$(printf '%s\n' "${rules}" | grep -n -- "-j ACCEPT" | tail -1 | cut -d: -f1)"
if [[ "${reject_line}" -gt "${last_accept}" ]]; then
    _t_pass "fill_net_chain puts the REJECT after every ACCEPT"
else
    _t_fail "fill_net_chain REJECT at ${reject_line} precedes an ACCEPT at ${last_accept}"
fi

# The reject-with argument differs per protocol and must be passed through.
_reset_ipt
fill_net_chain ip6tables icmp6-port-unreachable
case "$(_rules_of ip6tables)" in
    *"--reject-with icmp6-port-unreachable"*) _t_pass "fill_net_chain passes the v6 reject type through" ;;
    *) _t_fail "fill_net_chain must pass the caller's reject type" ;;
esac

# A non-numeric cache line must be skipped, not passed to iptables.
_reset_ipt
printf '10123\nnot-a-uid\n\n10456\n' >"${CURFEW_NET_UID_CACHE}"
fill_net_chain iptables icmp-port-unreachable
if _rules_of iptables | grep -q "not-a-uid"; then
    _t_fail "fill_net_chain passed a non-numeric uid to iptables"
else
    _t_pass "fill_net_chain skips non-numeric cache entries"
fi

# A missing cache is not fatal: the plumbing rules must still be laid down.
_reset_ipt
rm -f "${CURFEW_NET_UID_CACHE}"
fill_net_chain iptables icmp-port-unreachable
case "$(_rules_of iptables)" in
    *"10000-19999 -j REJECT"*) _t_pass "fill_net_chain still cuts off apps with no uid cache" ;;
    *) _t_fail "fill_net_chain must lay down the REJECT even with no cache" ;;
esac

# A failing flush aborts the fill rather than layering onto stale rules.
_reset_ipt
_fail_op F
if ! fill_net_chain iptables icmp-port-unreachable; then
    _t_pass "fill_net_chain fails when the chain cannot be flushed"
else
    _t_fail "fill_net_chain should fail when -F fails"
fi
_clear_fail F
