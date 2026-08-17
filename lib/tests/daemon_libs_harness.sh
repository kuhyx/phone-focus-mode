#!/usr/bin/env bash
# lib/tests/daemon_libs_harness.sh — the fake device behind the three
# libraries split out of focus_daemon.sh.
#
# Sourced, not executed. All three drive the phone through real binaries — pm,
# dumpsys, cmd, date — so the stubs go on PATH.
#
# `date` is stubbed rather than mocked as a function because is_curfew_now
# calls it in a command substitution; a shell function would work here but
# would not survive the subject being run any other way, and the point of the
# midnight-wrap cases is to pin the clock precisely.
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
mkdir -p "${RUN}/bin" "${RUN}/state" "${RUN}/dev"

readonly DEV="${RUN}/dev"

# --- stubs ------------------------------------------------------------------

# pm records every call and honours a per-package failure flag, so the
# "disable refused" branches are reachable.
cat >"${RUN}/bin/pm" <<'STUB'
#!/usr/bin/env bash
printf 'pm %s\n' "$*" >>"${DEV}/calls.log"
case "$1" in
list)
    [[ -f "${DEV}/pm_list" ]] && cat "${DEV}/pm_list"
    exit 0
    ;;
disable-user)
    pkg="${*: -1}"
    grep -qxF "${pkg}" "${DEV}/pm_undisableable" 2>/dev/null && exit 1
    printf '%s\n' "${pkg}" >>"${DEV}/disabled"
    exit 0
    ;;
enable)
    pkg="${*: -1}"
    grep -qxF "${pkg}" "${DEV}/pm_unenableable" 2>/dev/null && exit 1
    printf '%s\n' "${pkg}" >>"${DEV}/enabled"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "${RUN}/bin/pm"

cat >"${RUN}/bin/dumpsys" <<'STUB'
#!/usr/bin/env bash
printf 'dumpsys %s\n' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/dumpsys_out" ]] && cat "${DEV}/dumpsys_out"
exit 0
STUB
chmod +x "${RUN}/bin/dumpsys"

cat >"${RUN}/bin/cmd" <<'STUB'
#!/usr/bin/env bash
printf 'cmd %s\n' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/cmd_out" ]] && cat "${DEV}/cmd_out"
exit 0
STUB
chmod +x "${RUN}/bin/cmd"

# `date` answers from a pinned clock when one is set, so the curfew-window
# cases are deterministic rather than dependent on when the suite runs.
cat >"${RUN}/bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ -f "${DEV}/now" && "$1" == "+%H%M" ]]; then
    cat "${DEV}/now"
    exit 0
fi
exec /usr/bin/date "$@"
STUB
chmod +x "${RUN}/bin/date"

export DEV
export PATH="${RUN}/bin:${PATH}"

# --- ambient definitions the libraries expect from the daemon --------------

log() { printf '%s\n' "$*" >>"${DEV}/log"; }

STATE_DIR="${RUN}/state"
STATUS_FILE="${RUN}/state/status.json"
MODE_FILE="${RUN}/state/mode"
DISABLED_APPS_FILE="${RUN}/state/disabled_apps.txt"
CURFEW_FORCE_FILE="${RUN}/state/curfew_force"
CURFEW_OVERRIDE_FILE="${RUN}/state/curfew_override"
NIGHT_CURFEW_ENABLED=1
NIGHT_CURFEW_START="2300"
NIGHT_CURFEW_END="0500"
WHITELIST="com.allowed.one com.allowed.two"
NIGHT_WHITELIST="com.night.only"
SYSTEM_NEVER_DISABLE="com.android."
BLOCKED_SYSTEM_APPS="com.android.browser"
RADIUS=100

# Written by init/enable/disable in the entry script and read by main, so it
# lives there; the harness stands in for that ownership.
CURRENT_MODE="normal"
_CURFEW_TICK_CACHED=""
_CURFEW_TICK_RESULT=0

# shellcheck source=../../daemon_location.sh
. "${PHONE_DIR}/daemon_location.sh"
# shellcheck source=../../daemon_state.sh
. "${PHONE_DIR}/daemon_state.sh"
# shellcheck source=../../daemon_apps.sh
. "${PHONE_DIR}/daemon_apps.sh"

# --- helpers ----------------------------------------------------------------

_reset_dev() {
    rm -rf "${DEV}"
    mkdir -p "${DEV}"
    _CURFEW_TICK_CACHED=""
    _CURFEW_TICK_RESULT=0
}

_set_now() { printf '%s\n' "$1" >"${DEV}/now"; }
_calls() { cat "${DEV}/calls.log" 2>/dev/null || printf ''; }
_log() { cat "${DEV}/log" 2>/dev/null || printf ''; }
_disabled() { cat "${DEV}/disabled" 2>/dev/null || printf ''; }
_enabled() { cat "${DEV}/enabled" 2>/dev/null || printf ''; }

# Seed the installed third-party package list `pm list packages -3 -e` returns.
_seed_packages() {
    local pkg=""
    : >"${DEV}/pm_list"
    for pkg in "$@"; do
        printf 'package:%s\n' "${pkg}" >>"${DEV}/pm_list"
    done
}
