#!/usr/bin/env bash
# lib/tests/ctl_libs_harness.sh — the fake device behind the tests for the
# libraries split out of focus_ctl.sh.
#
# Sourced, not executed. The subcommands drive the phone through real binaries
# (pm, iptables, settings, setsid, ...), so the stubs go on PATH. The real
# config.sh supplies every default so this fixture cannot drift from the
# values the subcommands actually read; only the paths are redirected.
set -euo pipefail

# TESTS_DIR is declared readonly by the entry point that sources this file.
readonly PHONE_DIR="${TESTS_DIR}/../.."

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
mkdir -p "${RUN}/bin" "${RUN}/state"

readonly DEV="${RUN}/state"

# `date` answers from a pinned clock so the window cases are deterministic
# rather than dependent on when the suite happens to run.
cat >"${RUN}/bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ -f "${DEV}/now" && "$1" == "+%H%M" ]]; then
    cat "${DEV}/now"
    exit 0
fi
exec /usr/bin/date "$@"
STUB
chmod +x "${RUN}/bin/date"

# --- device stubs -----------------------------------------------------------
#
# Every cmd_* subcommand drives the phone through one of these. They log each
# call so a command's effect is assertable, and each honours a fail_<name>
# flag so the "not running" / "chain missing" branches are reachable.
#
# setsid is the important one: the start commands launch a real daemon with
# it. Stubbing it keeps the suite from spawning enforcers on this machine,
# and lets a test decide whether the launch "worked" by seeding the pidfile.
_mk_stub() {
    cat >"${RUN}/bin/$1" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$1" "\$*" >>"\${DEV}/calls.log"
[[ -f "\${DEV}/fail_$1" ]] && exit 1
[[ -f "\${DEV}/out_$1" ]] && cat "\${DEV}/out_$1"
exit 0
STUB
    chmod +x "${RUN}/bin/$1"
}

for _s in pm am settings dumpsys svc sqlite3 getprop content kill sleep setsid; do
    _mk_stub "$_s"
done

# iptables/ip6tables also model chain existence, so the MISSING branches and
# the rule counts in the status commands are both reachable.
cat >"${RUN}/bin/iptables" <<'STUB'
#!/usr/bin/env bash
bin="$(basename "$0")"
printf '%s %s\n' "$bin" "$*" >>"${DEV}/calls.log"
case "$1" in
-L) [[ -f "${DEV}/chain_${bin}" ]] && exit 0 || exit 1 ;;
-S) [[ -f "${DEV}/chain_${bin}" ]] && cat "${DEV}/chain_${bin}" || exit 1 ;;
esac
exit 0
STUB
chmod +x "${RUN}/bin/iptables"
cp "${RUN}/bin/iptables" "${RUN}/bin/ip6tables"

export DEV
export PATH="${RUN}/bin:${PATH}"

_calls() { cat "${DEV}/calls.log" 2>/dev/null || printf ''; }
_reset_calls() { : >"${DEV}/calls.log"; }
_fail_op() { touch "${DEV}/fail_$1"; }
_clear_fail() { rm -f "${DEV}/fail_$1"; }
_seed_out() { printf '%s\n' "$2" >"${DEV}/out_$1"; }
_seed_chain() { printf '%s\n' "${2:--A rule}" >"${DEV}/chain_$1"; }
_clear_chain() { rm -f "${DEV}/chain_$1"; }

_set_now() { printf '%s\n' "$1" >"${DEV}/now"; }

# --- ambient definitions the libraries expect from focus_ctl.sh ------------

log() { :; }

# The real config.sh supplies every default, so this fixture cannot drift
# from the values the subcommands actually read. FOCUS_MODE_SCRIPT_DIR points
# its SCRIPT_DIR at the checkout; the paths are then redirected at a temp dir
# so nothing here touches /data/local/tmp.
FOCUS_MODE_SCRIPT_DIR="${PHONE_DIR}"
export FOCUS_MODE_SCRIPT_DIR
# shellcheck source=../../config.sh
. "${PHONE_DIR}/config.sh"

STATE_DIR="${RUN}/state"
LOG_FILE="${STATE_DIR}/focus.log"
MODE_FILE="${STATE_DIR}/mode"
STATUS_FILE="${STATE_DIR}/status.json"
DISABLED_APPS_FILE="${STATE_DIR}/disabled.txt"
DISABLED_COMPETITORS_FILE="${STATE_DIR}/competitors.txt"
RECHECK_TRIGGER="${STATE_DIR}/trigger_recheck"
CURFEW_OVERRIDE_FILE="${STATE_DIR}/curfew_override"
CURFEW_FORCE_FILE="${STATE_DIR}/curfew_force"
CURFEW_ENFORCER_STATE="${STATE_DIR}/curfew_applied"
CURFEW_ENFORCER_LOG="${STATE_DIR}/curfew.log"
TETHER_FORCE_FILE="${STATE_DIR}/tether_force"
TETHER_OVERRIDE_FILE="${STATE_DIR}/tether_override"
TETHER_ENFORCER_STATE="${STATE_DIR}/tether_applied"
TETHER_LOG="${STATE_DIR}/tether.log"
HOSTS_LOG="${STATE_DIR}/hosts.log"
HOSTS_CANONICAL="${STATE_DIR}/hosts.canonical"
HOSTS_SHA_FILE="${STATE_DIR}/hosts.sha256"
HOSTS_TARGET="${STATE_DIR}/hosts_target"
DNS_LOG="${STATE_DIR}/dns.log"
LAUNCHER_LOG="${STATE_DIR}/launcher.log"
LAUNCHER_ACTIVITY_FILE="${STATE_DIR}/launcher.activity"
LAUNCHER_APK="${STATE_DIR}/launcher.apk"
LAUNCHER_SHA_FILE="${STATE_DIR}/launcher.sha256"
WORKOUT_DETECTOR_LOG="${STATE_DIR}/workout.log"
WORKOUT_ACTIVE_FILE="${STATE_DIR}/workout_active"
WORKOUT_DB_PATH="${STATE_DIR}/stronglifts.db"
WORKOUT_SQLITE3_BIN="${RUN}/bin/sqlite3"
NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"

# shellcheck source=../../ctl_curfew.sh
. "${PHONE_DIR}/ctl_curfew.sh"
# shellcheck source=../../ctl_hosts.sh
. "${PHONE_DIR}/ctl_hosts.sh"
# shellcheck source=../../ctl_dns.sh
. "${PHONE_DIR}/ctl_dns.sh"
# shellcheck source=../../ctl_launcher.sh
. "${PHONE_DIR}/ctl_launcher.sh"
# shellcheck source=../../ctl_workout.sh
. "${PHONE_DIR}/ctl_workout.sh"
# shellcheck source=../../ctl_tether.sh
. "${PHONE_DIR}/ctl_tether.sh"
# shellcheck source=../../ctl_daemon.sh
. "${PHONE_DIR}/ctl_daemon.sh"
# shellcheck source=../../ctl_usage.sh
. "${PHONE_DIR}/ctl_usage.sh"
