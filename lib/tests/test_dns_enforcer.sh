#!/usr/bin/env bash
# Unit tests for dns_enforcer.sh helper functions.
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
export STATE_DIR="${TMPDIR_TEST}"
export MODE_FILE="${TMPDIR_TEST}/current_mode.txt"
export DNS_LOG="${TMPDIR_TEST}/dns.log"
export DNS_IPT_CHAIN="FOCUS_DNS_BLOCK"
export DNS_CHECK_INTERVAL=20
export DNS_DOH_IPV4=""
export DNS_DOH_IPV6=""
export DNS_BLOCK_HOSTS=""
export DNS_BLOCK_PACKAGES_ALWAYS=""
export DNS_BLOCK_PACKAGES_FOCUS_ONLY=""
EOF

export FOCUS_MODE_DNS_ENFORCER_TESTING=1
export FOCUS_MODE_SCRIPT_DIR="${TMPDIR_TEST}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../dns_enforcer.sh"

line_ipv4='Ping youtube.com (142.251.98.190): 56(84) bytes.'
line_ipv6='Ping youtube.com (2a00:1450:4025:800::5b): 56(84) bytes.'

if [[ "$(extract_ping_ip "$line_ipv4")" == "142.251.98.190" ]]; then
    _t_pass "extract_ping_ip parses IPv4"
else
    _t_fail "extract_ping_ip failed for IPv4"
fi

if [[ "$(extract_ping_ip "$line_ipv6")" == "2a00:1450:4025:800::5b" ]]; then
    _t_pass "extract_ping_ip parses IPv6"
else
    _t_fail "extract_ping_ip failed for IPv6"
fi

pkg_line='package:com.android.chrome uid:10153'
if [[ "$(extract_package_uid "$pkg_line")" == "10153" ]]; then
    _t_pass "extract_package_uid parses uid from package line"
else
    _t_fail "extract_package_uid failed for package line"
fi

bad_pkg_line='package:com.android.chrome'
if [[ -z "$(extract_package_uid "$bad_pkg_line")" ]]; then
    _t_pass "extract_package_uid returns empty when uid is missing"
else
    _t_fail "extract_package_uid should return empty when uid missing"
fi

block_file="${TMPDIR_TEST}/block.txt"
: >"$block_file"
append_unique_line "$block_file" "1.2.3.4"
append_unique_line "$block_file" "1.2.3.4"
append_unique_line "$block_file" "5.6.7.8"

if [[ "$(wc -l < "$block_file" | tr -d ' ')" == "2" ]]; then
    _t_pass "append_unique_line de-duplicates values"
else
    _t_fail "append_unique_line should avoid duplicates"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
