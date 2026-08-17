#!/usr/bin/env bash
# lib/tests/monitor_harness.sh — the fake device behind the monitor.sh tests.
#
# Sourced, not executed. Unlike dns_iptables_harness.sh there are no PATH
# stubs here: every probe in monitor_checks_{health,policy}.sh reaches the
# device through adb_root_shell, which is a *function* from adb_common.sh, so
# a stub binary on PATH would never be consulted. Mocking at the function
# boundary is both sufficient and far cheaper — it keeps adb_common.sh's
# device-detection and locking surface out of the test entirely.
#
# monitor.sh and monitor_checks_policy.sh declare readonly constants, so the
# subject can be sourced exactly once per process. State is therefore reset
# through the mock's own store (_dev_reset), never by re-sourcing.
set -euo pipefail

_MH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _MH_DIR

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

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

readonly DEV="${TEST_TMPDIR}/device"

# --- device state -----------------------------------------------------------
#
# One file per fact the probes can observe. Seeding a fact is writing a file;
# the mock never grows a new case arm when a test wants a new scenario. That
# is the _seed_jumps/_fail_op idea from dns_iptables_harness.sh lifted to the
# function boundary.

_dev_reset() {
    rm -rf "${DEV}"
    mkdir -p "${DEV}"
}

# _dev_set <key> <value> — record an observable value (battery level, a hash).
_dev_set() {
    printf '%s' "$2" >"${DEV}/$1"
}

# _dev_get <key> [default] — read one back, or the default when never seeded.
_dev_get() {
    if [[ -f "${DEV}/$1" ]]; then
        cat "${DEV}/$1"
    else
        printf '%s' "${2:-}"
    fi
}

# _dev_present <path...> — mark files/paths as existing for `test -f`/`-x`/-s.
_dev_present() {
    local path=""
    for path in "$@"; do
        printf '%s\n' "${path}" >>"${DEV}/present"
    done
}

_dev_has() {
    [[ -f "${DEV}/present" ]] && grep -qxF "$1" "${DEV}/present"
}

# _dev_pid <pid> — mark a PID as alive for `kill -0`.
_dev_pid() {
    printf '%s\n' "$1" >>"${DEV}/pids"
}

_dev_pid_alive() {
    [[ -f "${DEV}/pids" ]] && grep -qxF "$1" "${DEV}/pids"
}

# _dev_cmdline <pid> <text> — what /proc/<pid>/cmdline greps against. Absent
# means the grep fails, which is the "Android hides cmdline" path.
_dev_cmdline() {
    printf '%s' "$2" >"${DEV}/cmdline_$1"
}

# --- the mock ---------------------------------------------------------------
#
# Dispatch is by *pattern*, not exact string: the real commands embed awk
# programs with escaped $2, nested quotes and 2>/dev/null redirections, which
# an exact-match case arm cannot survive being edited around.
#
# Contract matches the real adb_root_shell: stdout is the command output,
# exit status is the command's status.
adb_root_shell() {
    local cmd="$*"

    case "${cmd}" in
        'test -f '*|'test -x '*|"test -s '"*)
            local target="${cmd#test -? }"
            target="${target#\'}"
            target="${target%\'}"
            _dev_has "${target}"
            ;;
        'kill -0 '*)
            local pid="${cmd#kill -0 }"
            pid="${pid%% *}"
            _dev_pid_alive "${pid}"
            ;;
        *'/cmdline'*)
            # tr '\0' ' ' </proc/<pid>/cmdline | grep -q <script_name>
            local pid="${cmd#*/proc/}"
            pid="${pid%%/*}"
            local want="${cmd##* }"
            [[ -f "${DEV}/cmdline_${pid}" ]] && grep -qF "${want}" "${DEV}/cmdline_${pid}"
            ;;
        *'dumpsys battery'*'level:'*) _dev_emit battery_level ;;
        *'dumpsys battery'*'health:'*) _dev_emit battery_health ;;
        *'dumpsys battery'*'temperature:'*) _dev_emit battery_temp ;;
        *'df /sdcard'*) _dev_emit df_sdcard ;;
        *'df /storage/emulated/0'*) _dev_emit df_emulated ;;
        'pgrep -f '*) _dev_emit "pgrep_$(_mh_script_of "${cmd}")" ;;
        *'cat /data/local/tmp/focus_mode/'*'.pid'*) _dev_emit "pidfile_$(_mh_pidfile_of "${cmd}")" ;;
        *'sha256sum'*) _dev_emit hosts_actual_sha ;;
        *'cat /data/local/tmp/focus_mode/hosts.sha256'*) _dev_emit hosts_expected_sha ;;
        *'cat /data/local/tmp/focus_mode/minimalist_launcher.activity'*) _dev_emit launcher_desired ;;
        *'resolve-activity'*) _dev_emit launcher_actual ;;
        *'settings get global private_dns_mode'*) _dev_emit private_dns_mode ;;
        *'iptables -L '*) _dev_has "dns_chain" ;;
        'pm path '*) _dev_has "pkg_launcher" ;;
        'pm list packages -e '*) _dev_has "pkg_companion" ;;
        *) return 1 ;;
    esac
}

# Emit a seeded value on stdout, failing like a real command when unseeded so
# that _safe_adb_root_output's `|| true` path stays reachable.
_dev_emit() {
    [[ -f "${DEV}/$1" ]] || return 1
    cat "${DEV}/$1"
}

# `pgrep -f 'foo.sh' 2>/dev/null | head -1` -> foo.sh
_mh_script_of() {
    local rest="${1#pgrep -f \'}"
    printf '%s' "${rest%%\'*}"
}

# `if [ -f /.../daemon.pid ]; then cat /.../daemon.pid; fi` -> daemon
_mh_pidfile_of() {
    local rest="${1##*focus_mode/}"
    printf '%s' "${rest%%.pid*}"
}

# --- ambient definitions the subject expects from its callers ---------------

_info() { :; }
_warn() { :; }
_error() { :; }
_box() { :; }

_fatal() {
    printf 'FATAL: %s\n' "$*" >&2
    exit 1
}

FORMAT_INDICATORS=()
FORMAT_DETECTION_MIN_MISSING=2
BATTERY_WARN_BELOW=20
STORAGE_WARN_BELOW_MB=500
ADB_SERIAL="test-serial"

: "${FORMAT_DETECTION_MIN_MISSING}" "${BATTERY_WARN_BELOW}"
: "${STORAGE_WARN_BELOW_MB}" "${ADB_SERIAL}" "${FORMAT_INDICATORS[*]}"

_dev_reset

# shellcheck source=../monitor.sh
. "${_MH_DIR}/../monitor.sh"

# --- probe drivers ----------------------------------------------------------

# _probe <fn> [args...] — run one _check_* into a fresh file and echo the JSON.
# Guarded: a probe that exits nonzero under `set -e` would otherwise abort the
# whole suite mid-run and still leave a plausible-looking coverage figure.
_probe() {
    local out="${TEST_TMPDIR}/probe.json"
    : >"${out}"
    "$@" "${out}" || printf '{"status":"PROBE-FAILED"}' >"${out}"
    cat "${out}"
}

# _field <json> <key> — pull one string field out of a probe's JSON line.
_field() {
    local json="$1" key="$2"
    [[ "${json}" =~ \"${key}\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}
