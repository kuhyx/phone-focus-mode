#!/usr/bin/env bash
# lib/tests/hosts_libs_harness.sh — the fake device behind the hosts_mount.sh
# and hosts_magisk.sh tests.
#
# Sourced, not executed. Both libraries drive the device through real binaries
# — mount, umount, chattr, am, pgrep, stop/start — so the stubs go on PATH,
# the same call as curfew_net's rather than monitor's function mocks.
#
# /proc/self/mounts is read directly by two functions, and cannot be stubbed
# on PATH. Those functions are handed a redirectable path instead: MOUNTS_FILE
# is substituted into the staged copy, so the subject under test reads a file
# the harness controls while the shipped code keeps its literal path.
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
mkdir -p "${RUN}/app" "${RUN}/bin" "${RUN}/state" "${RUN}/dev"

readonly DEV="${RUN}/dev"
readonly MOUNTS_FILE="${RUN}/state/mounts"
: >"${MOUNTS_FILE}"

# Stage the subjects with /proc/self/mounts redirected at the harness copy.
# The pattern uses a character class for the slash-separated path so no
# literal /proc path appears twice in this file.
sed "s#/proc/self/mounts#${MOUNTS_FILE}#g" \
    "${PHONE_DIR}/hosts_mount.sh" >"${RUN}/app/hosts_mount.sh"
# Same treatment for the Fenix profile glob: it is a hardcoded /data/data
# path that cannot exist here, so the staged copy points at a temp dir the
# harness controls. The shipped file keeps its literal path.
readonly FENIX_DIR="${RUN}/state/fenix"
mkdir -p "${FENIX_DIR}"
sed "s#/data/data/org.mozilla.fenix/files/mozilla/#${FENIX_DIR}/#" \
    "${PHONE_DIR}/hosts_magisk.sh" >"${RUN}/app/hosts_magisk.sh"

# --- stubs ------------------------------------------------------------------
#
# Each records its calls so behaviour is assertable, and each honours a
# fail_<name> flag so the error branches are reachable.

_mk_stub() {
    local name="$1"
    cat >"${RUN}/bin/${name}" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"\${DEV}/calls.log"
[[ -f "\${DEV}/fail_${name}" ]] && exit 1
exit 0
STUB
    chmod +x "${RUN}/bin/${name}"
}

# sleep is stubbed too: restart_netd_for_hosts_cache sleeps 2s twice, and a
# 4s pause per call is real time spent proving nothing.
for _s in chattr chmod am stop start umount sleep; do
    _mk_stub "$_s"
done

# cp is its own stub: make_target_writable_once's overwrite is the fallback
# path, so a test has to be able to let that copy actually land.
cat >"${RUN}/bin/cp" <<'STUB'
#!/usr/bin/env bash
printf 'cp %s
' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/fail_cp" ]] && exit 1
[[ -f "${DEV}/overwrite_works" ]] && cat <"$1" >"$2" 2>/dev/null
exit 0
STUB
chmod +x "${RUN}/bin/cp"

# mount also maintains the fake mounts file, so a bind shows up afterwards.
cat >"${RUN}/bin/mount" <<'STUB'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/fail_mount" ]] && exit 1
if [[ "$1" == "--bind" ]]; then
    printf 'src %s rw 0 0\n' "$3" >>"${MOUNTS_FILE}"
    # A bind mount makes the target's content equal the source's.
    # Redirection, not cp: this stub runs with the stub dir on PATH, so a
    # `cp` here would hit the cp stub and copy nothing.
    [[ -f "${DEV}/bind_is_noop" ]] || cat <"$2" >"$3" 2>/dev/null || true
fi
exit 0
STUB
chmod +x "${RUN}/bin/mount"

# umount clears the fake mounts file one entry at a time.
cat >"${RUN}/bin/umount" <<'STUB'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/fail_umount" ]] && exit 1
target="${*: -1}"
# When asked, report success but leave the entry: a mount that will not go
# away, which is what the give-up-after-5-attempts branch exists for.
[[ -f "${DEV}/umount_is_noop" ]] && exit 0
if [[ -s "${MOUNTS_FILE}" ]]; then
    grep -vF " ${target} " "${MOUNTS_FILE}" >"${MOUNTS_FILE}.new" 2>/dev/null || : >"${MOUNTS_FILE}.new"
    mv "${MOUNTS_FILE}.new" "${MOUNTS_FILE}"
fi
exit 0
STUB
chmod +x "${RUN}/bin/umount"

cat >"${RUN}/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"${DEV}/calls.log"
[[ -f "${DEV}/netd_pid" ]] || exit 1
cat "${DEV}/netd_pid"
STUB
chmod +x "${RUN}/bin/pgrep"

export DEV MOUNTS_FILE
export PATH="${RUN}/bin:${PATH}"

# --- ambient definitions the libraries expect from the enforcer ------------

log() { printf '%s\n' "$*" >>"${DEV}/log"; }

# The real one lives in hosts_enforcer.sh; both libraries call it.
sha256_of() {
    [ -f "$1" ] || return 0
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

STATE_DIR="${RUN}/state"
HOSTS_TARGET="${RUN}/state/hosts_target"
HOSTS_CANONICAL="${RUN}/state/hosts.canonical"
HOSTS_CANONICAL_WORKOUT="${RUN}/state/hosts.canonical.workout"
HOSTS_MAGISK_MODULE_FILE="${RUN}/state/modules/hosts/system/etc/hosts"
BROWSER_PACKAGES="org.mozilla.fenix com.android.chrome"
WORKOUT_ACTIVE_FILE="${RUN}/state/workout_active"

# hosts_mount.sh calls current_canonical, which lives in the entry script.
# Modelled here as the same two-variant choice the real one makes.
current_canonical() {
    if [ -f "$WORKOUT_ACTIVE_FILE" ]; then
        printf '%s' "$HOSTS_CANONICAL_WORKOUT"
    else
        printf '%s' "$HOSTS_CANONICAL"
    fi
}

# shellcheck source=../../hosts_magisk.sh
. "${RUN}/app/hosts_magisk.sh"
# shellcheck source=../../hosts_mount.sh
. "${RUN}/app/hosts_mount.sh"

# --- helpers ----------------------------------------------------------------

_reset_dev() {
    rm -rf "${DEV}"
    mkdir -p "${DEV}"
    : >"${MOUNTS_FILE}"
}

# A copy the stubs cannot intercept: the cp stub exists to observe the
# subject's calls, but the harness and cases need to actually move bytes.
# Redirection is a shell builtin, so it bypasses PATH entirely.
_copy() {
    cat <"$1" >"$2"
}

_fail_op() { touch "${DEV}/fail_$1"; }
_clear_fail() { rm -f "${DEV}/fail_$1"; }

_calls() { cat "${DEV}/calls.log" 2>/dev/null || printf ''; }
_log() { cat "${DEV}/log" 2>/dev/null || printf ''; }

# Record TARGET as already mounted, the OEM-overlay state assert_bind_mount
# has to clear before it can take the path over.
_seed_mount() {
    printf 'src %s rw 0 0\n' "${HOSTS_TARGET}" >>"${MOUNTS_FILE}"
}
