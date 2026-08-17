#!/usr/bin/env bash
# Unit tests for dns_iptables.sh — the chain half of dns_enforcer.sh.
#
# The predecessor of this file, test_dns_enforcer.sh, asserted against three
# functions that dns_enforcer.sh has never defined, so it never ran a single
# assertion. It was deleted rather than repaired.
#
# Staging, stubs and assertion helpers live in dns_iptables_harness.sh.
set -euo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dns_iptables_harness.sh
. "${_TEST_DIR}/dns_iptables_harness.sh"

printf '\nexpected_rule_count\n'

_reset_ipt
# 2 fixed DoT rules + 4 per DoH IP; no trusted resolver configured.
_t_eq "10" "$(_with_subject <<'CASE'
expected_rule_count 4 1.1.1.1 8.8.8.8
CASE
)" \
    "counts 2 fixed + 4 per DoH IP"

_reset_ipt
_t_eq "2" "$(_with_subject <<'CASE'
expected_rule_count 4
CASE
)" \
    "counts only the 2 fixed DoT rules when no IPs are given"

_reset_ipt
# A commented-out entry must not be counted, or chain_intact never converges.
_t_eq "6" "$(_with_subject <<'CASE'
expected_rule_count 4 1.1.1.1 "#8.8.8.8"
CASE
)" \
    "skips a commented-out DoH IP"

_reset_ipt
_t_eq "6" "$(_with_subject <<'CASE'
expected_rule_count 4 1.1.1.1 ""
CASE
)" \
    "skips an empty DoH IP"

_reset_ipt
_t_eq "7" "$(TEST_DOT_HOST=dns.example.net TEST_DOT_IPS=9.9.9.9 \
    _with_subject <<'CASE'
expected_rule_count 4 1.1.1.1
CASE
)" \
    "adds one ACCEPT per trusted v4 resolver address"

printf '\ntrusted_dot_ips\n'

_reset_ipt
_t_eq "" "$(_with_subject <<'CASE'
trusted_dot_ips 4
CASE
)" \
    "yields nothing when no trusted host is set"

_reset_ipt
_t_eq "9.9.9.9" "$(TEST_DOT_HOST=dns.example.net TEST_DOT_IPS='9.9.9.9 2620:fe::9' \
    _with_subject <<'CASE'
trusted_dot_ips 4
CASE
)" \
    "selects only the v4 address for family 4"

_reset_ipt
_t_eq "2620:fe::9" "$(TEST_DOT_HOST=dns.example.net TEST_DOT_IPS='9.9.9.9 2620:fe::9' \
    _with_subject <<'CASE'
trusted_dot_ips 6
CASE
)" \
    "selects only the v6 address for family 6"

_reset_ipt
_t_eq "" "$(TEST_DOT_HOST=dns.example.net TEST_DOT_IPS='#9.9.9.9' \
    _with_subject <<'CASE'
trusted_dot_ips 4
CASE
)" \
    "skips a commented-out trusted address"

printf '\nensure_chain\n'

_reset_ipt
_t_eq "0" "$(_with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1; echo $?
CASE
)" \
    "creates the chain and inserts the OUTPUT jump"

_reset_ipt
_t_eq "0" "$(_with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1
ensure_chain iptables >/dev/null 2>&1; echo $?
CASE
)" \
    "is idempotent across repeated calls"

printf '\nfill_chain_v4 / fill_chain_v6\n'

_reset_ipt
_t_eq "10" "$(_with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1
fill_chain_v4 >/dev/null 2>&1
iptables -S "$DNS_IPT_CHAIN" | grep -c "^-A"
CASE
)" \
    "fills v4 to exactly expected_rule_count rules"

_reset_ipt
# The ACCEPT for the trusted resolver must precede the blanket REJECT, or
# iptables' first-match wins and the allow rule is dead.
_t_eq "ACCEPT" "$(TEST_DOT_HOST=dns.example.net TEST_DOT_IPS=9.9.9.9 \
    _with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1
fill_chain_v4 >/dev/null 2>&1
iptables -S "$DNS_IPT_CHAIN" | head -1 | grep -o "ACCEPT\|REJECT"
CASE
)" \
    "puts the trusted-resolver ACCEPT before the blanket REJECT"

_reset_ipt
_t_eq "6" "$(_with_subject <<'CASE'
ensure_chain ip6tables >/dev/null 2>&1
fill_chain_v6 >/dev/null 2>&1
ip6tables -S "$DNS_IPT_CHAIN" | grep -c "^-A"
CASE
)" \
    "fills v6 to 2 fixed + 4 for the single DoH v6 IP"

printf '\nchain_intact\n'

_reset_ipt
_t_eq "1" "$(_with_subject <<'CASE'
chain_intact iptables 10 >/dev/null 2>&1; echo $?
CASE
)" \
    "reports drift when the OUTPUT jump is missing"

_reset_ipt
_t_eq "0" "$(_with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1
fill_chain_v4 >/dev/null 2>&1
chain_intact iptables 10 >/dev/null 2>&1; echo $?
CASE
)" \
    "reports intact when jump and rule count both match"

_reset_ipt
_t_eq "1" "$(_with_subject <<'CASE'
ensure_chain iptables >/dev/null 2>&1
fill_chain_v4 >/dev/null 2>&1
chain_intact iptables 99 >/dev/null 2>&1; echo $?
CASE
)" \
    "reports drift when the rule count disagrees"

printf '\nenforce_iptables\n'

_reset_ipt
# The whole point of the module: one call brings both families to a state
# that chain_intact then accepts, so the daemon settles instead of rebuilding.
_t_eq "0" "$(_with_subject <<'CASE'
enforce_iptables >/dev/null 2>&1
chain_intact iptables "$(expected_rule_count 4 $DNS_DOH_IPV4)" \
>/dev/null 2>&1; echo $?
CASE
)" \
    "converges v4 to a state chain_intact accepts"

_reset_ipt
_t_eq "0" "$(_with_subject <<'CASE'
enforce_iptables >/dev/null 2>&1
chain_intact ip6tables "$(expected_rule_count 6 $DNS_DOH_IPV6)" \
>/dev/null 2>&1; echo $?
CASE
)" \
    "converges v6 to a state chain_intact accepts"

_reset_ipt
# Second call must be a no-op at the rule level, not a rebuild.
_t_eq "10" "$(_with_subject <<'CASE'
enforce_iptables >/dev/null 2>&1
enforce_iptables >/dev/null 2>&1
iptables -S "$DNS_IPT_CHAIN" | grep -c "^-A"
CASE
)" \
    "stays at the same rule count when run twice"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
