#!/usr/bin/env bash
# dns_iptables_harness.sh — staging and assertions shared by the
# dns_iptables.sh test runners.
#
# Sourced, not executed. Stages dns_enforcer.sh + dns_iptables.sh into a temp
# dir beside a fake config.sh, stubs iptables/ip6tables/settings, and exposes
# _with_subject to run a snippet against the staged copy. The caller owns PASS
# and FAIL and prints the tally.
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

# Assert two strings match, naming the expectation either way.
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

cp "${PHONE_DIR}/dns_enforcer.sh" "${PHONE_DIR}/dns_iptables.sh" "${RUN}/app/"

# --- fake config.sh in the script's own dir (dns_enforcer sources a sibling) ---
cat >"${RUN}/app/config.sh" <<EOF
export STATE_DIR="${RUN}/state"
export DNS_LOG="${RUN}/state/dns.log"
export DNS_IPT_CHAIN="FOCUS_DNS_BLOCK"
export DNS_CHECK_INTERVAL=1
export DNS_DOH_IPV4="1.1.1.1 8.8.8.8"
export DNS_DOH_IPV6="2606:4700:4700::1111"
export DNS_TRUSTED_DOT_HOST="\${TEST_DOT_HOST:-}"
export DNS_TRUSTED_DOT_IPS="\${TEST_DOT_IPS:-}"
EOF

# --- iptables/ip6tables stub: a rule list per binary, plus the OUTPUT jump ---
cat >"${RUN}/bin/iptables" <<'STUB'
#!/usr/bin/env bash
# Models only what the functions under test inspect: a per-binary rule file
# and a flag for the OUTPUT -> chain jump. Every call is logged so tests can
# assert on ordering, which is what makes the ACCEPT-before-REJECT rule
# checkable without a real firewall.
bin="$(basename "$0")"
store="${IPT_STATE}/${bin}"
mkdir -p "$store"
rules="${store}/rules"
jump="${store}/jump"
touch "$rules"
printf '%s %s\n' "$bin" "$*" >>"${IPT_STATE}/calls.log"

case "$1" in
-L) [[ -f "${store}/chain" ]] && exit 0 || exit 1 ;;
-N) touch "${store}/chain"; exit 0 ;;
-F) : >"$rules"; exit 0 ;;
-A)
    shift
    printf -- '-A %s\n' "$*" >>"$rules"
    exit 0
    ;;
-I) touch "$jump"; exit 0 ;;
-D)
    # Succeeds once per existing jump, so the de-dupe loop terminates.
    if [[ -f "$jump" ]]; then rm -f "$jump"; exit 0; fi
    exit 1
    ;;
-C) [[ -f "$jump" ]] && exit 0 || exit 1 ;;
-S) cat "$rules"; exit 0 ;;
esac
exit 0
STUB
chmod +x "${RUN}/bin/iptables"
cp "${RUN}/bin/iptables" "${RUN}/bin/ip6tables"

# `settings` is only reached via ensure_private_dns_*, which these tests do
# not exercise; stubbed so an accidental call cannot hit a real binary.
cat >"${RUN}/bin/settings" <<'STUB'
#!/usr/bin/env bash
echo "null"
STUB
chmod +x "${RUN}/bin/settings"

# Build a sourceable copy: main() would otherwise loop forever. The pattern
# uses a character class for the dollar so that no literal expansion appears
# in this file, keeping the intent readable without a lint suppression.
sed 's/^main "[$]@"$/: # main disabled under test/' \
    "${RUN}/app/dns_enforcer.sh" >"${RUN}/app/under_test.sh"

# Run a snippet with the subject sourced, under the stub PATH. Executed as a
# subprocess rather than sourced here so that $0 — and therefore SCRIPT_DIR —
# resolves to the app dir, which is how the script finds its siblings.
#
# The snippet is read from stdin rather than taken as an argument: it is code
# for the *subject* to expand, so any $VAR in it must survive this file
# untouched. A heredoc says that plainly, where a quoted argument would look
# like an expansion bug and draw SC2016.
_with_subject() {
    {
        cat <<'PRELUDE'
#!/usr/bin/env bash
. "$(cd "$(dirname "$0")" && pwd)/under_test.sh"
PRELUDE
        cat
    } >"${RUN}/app/case.sh"
    PATH="${RUN}/bin:${PATH}" IPT_STATE="${RUN}/ipt" \
        TEST_DOT_HOST="${TEST_DOT_HOST:-}" TEST_DOT_IPS="${TEST_DOT_IPS:-}" \
        bash "${RUN}/app/case.sh"
}

_reset_ipt() {
    rm -rf "${RUN}/ipt"
    mkdir -p "${RUN}/ipt"
}
