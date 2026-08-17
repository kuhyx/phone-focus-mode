#!/usr/bin/env bash
# lib/tests/curfew_net_harness.sh — staging and stubs for the curfew_net.sh
# tests.
#
# Sourced, not executed. Unlike the monitor tests, the stubs here go on PATH:
# curfew_net.sh calls iptables, ip6tables and pm as real binaries, so the
# process boundary is where the fake has to sit. Modelled on
# dns_iptables_harness.sh, which stubs the same two firewall binaries.
#
# The stub records every call in order, which is what makes the rule ordering
# assertable — the ACCEPT rules must precede the 10000-19999 REJECT or the
# whitelist is meaningless.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PHONE_DIR="${SCRIPT_DIR}/../.."

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

_t_eq() {
    local want="$1" got="$2" what="$3"
    if [[ "$got" == "$want" ]]; then
        _t_pass "$what"
    else
        _t_fail "$what (want '${want}', got '${got}')"
    fi
}

RUN="$(mktemp -d)"
trap 'rm -rf "${RUN}"' EXIT
mkdir -p "${RUN}/app" "${RUN}/bin" "${RUN}/state" "${RUN}/ipt"

cp "${PHONE_DIR}/curfew_net.sh" "${RUN}/app/"

# --- iptables/ip6tables stub ------------------------------------------------
#
# Models a per-binary chain flag, a rule list and the OUTPUT jump count. Every
# call is logged so ordering can be asserted. Failure injection mirrors
# dns_iptables_harness.sh: a test touches fail_<op> to make that operation
# report failure, which is how the error returns become reachable.
cat >"${RUN}/bin/iptables" <<'STUB'
#!/usr/bin/env bash
bin="$(basename "$0")"
store="${IPT_STATE}/${bin}"
mkdir -p "$store"
rules="${store}/rules"
touch "$rules"

# curfew_net always calls through iptw, which prepends `-w 2`. Drop it so the
# case below matches on the real operation.
[[ "$1" == "-w" ]] && shift 2

printf '%s %s\n' "$bin" "$*" >>"${IPT_STATE}/calls.log"

_fails() { [[ -f "${IPT_STATE}/fail_$1" ]]; }

_jumps_file="${store}/jumps"
[[ -f "$_jumps_file" ]] || echo 0 >"$_jumps_file"

case "$1" in
-L) [[ -f "${store}/chain" ]] && exit 0 || exit 1 ;;
-N)
    _fails N && exit 1
    touch "${store}/chain"
    exit 0
    ;;
-F)
    _fails F && exit 1
    : >"$rules"
    exit 0
    ;;
-X)
    rm -f "${store}/chain"
    exit 0
    ;;
-A)
    shift
    printf -- '%s\n' "$*" >>"$rules"
    exit 0
    ;;
-I)
    _fails I && exit 1
    read -r n <"$_jumps_file"
    echo $((n + 1)) >"$_jumps_file"
    exit 0
    ;;
-D)
    # Succeeds once per existing jump so the de-dupe loop terminates.
    read -r n <"$_jumps_file"
    if ((n > 0)); then
        echo $((n - 1)) >"$_jumps_file"
        exit 0
    fi
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "${RUN}/bin/iptables"
cp "${RUN}/bin/iptables" "${RUN}/bin/ip6tables"

# `pm list packages -U` output, seeded per test via PM_FIXTURE.
cat >"${RUN}/bin/pm" <<'STUB'
#!/usr/bin/env bash
[[ -f "${PM_FIXTURE}" ]] && cat "${PM_FIXTURE}"
exit 0
STUB
chmod +x "${RUN}/bin/pm"

export IPT_STATE="${RUN}/ipt"
export PM_FIXTURE="${RUN}/state/pm.txt"
export PATH="${RUN}/bin:${PATH}"

# --- ambient globals the library reads from config.sh / the enforcer --------

STATE_DIR="${RUN}/state"
CURFEW_NET_IPT_CHAIN="FOCUS_CURFEW_NET"
CURFEW_NET_UID_CACHE="${RUN}/state/curfew_uids.cache"
CURFEW_NET_REASSERT_INTERVAL=1
CURFEW_NET_ENABLED=1
NET_BUILT=""

log() { printf '%s\n' "$*" >>"${RUN}/state/log"; }

# shellcheck source=../../curfew_net.sh
. "${RUN}/app/curfew_net.sh"

_reset_ipt() {
    rm -rf "${RUN}/ipt"
    mkdir -p "${RUN}/ipt"
}

# Make the next run report the given iptables operation as failing.
_fail_op() {
    touch "${RUN}/ipt/fail_$1"
}

_clear_fail() {
    rm -f "${RUN}/ipt/fail_$1"
}

# Pre-seed the chain as existing with N stale OUTPUT jumps, the lock-race
# state ensure_net_chain's de-dupe loop exists to clean up.
_seed_jumps() {
    local bin="$1" count="$2"
    mkdir -p "${RUN}/ipt/${bin}"
    touch "${RUN}/ipt/${bin}/chain"
    echo "$count" >"${RUN}/ipt/${bin}/jumps"
}

# Rules recorded for a binary, one per line.
_rules_of() {
    cat "${RUN}/ipt/$1/rules" 2>/dev/null || printf ''
}

_calls() {
    cat "${RUN}/ipt/calls.log" 2>/dev/null || printf ''
}
