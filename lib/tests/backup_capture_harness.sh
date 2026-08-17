#!/usr/bin/env bash
# lib/tests/backup_capture_harness.sh — the fake device behind the
# backup_capture.sh tests.
#
# Sourced, not executed. Every function in backup_capture.sh reaches the
# phone through adb_cmd, so mocking that one function covers the library
# without pulling in adb_common.sh's device-detection surface. The mock
# records what it was asked to pull, which is what makes the two
# stdin-draining bugs the comments in pull_apks/pull_sdcard describe
# testable: a regression there pulls 1 package instead of all of them.
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
mkdir -p "${DEV}"

_info() { :; }
_warn() { printf 'warn: %s\n' "$*" >>"${DEV}/warnings"; }

# The fake device. Dispatch is by pattern because the real calls carry
# trailing redirections and quoted find expressions.
adb_cmd() {
    local args="$*"

    case "${args}" in
        'shell pm list packages')
            printf 'package:com.android.systemui\npackage:com.example.one\npackage:com.example.two\r\n'
            ;;
        'shell pm list packages -3')
            printf 'package:com.example.one\npackage:com.example.two\r\n'
            ;;
        'shell pm list packages -u')
            printf 'package:com.android.systemui\npackage:com.example.one\npackage:com.example.two\npackage:com.purged.app\r\n'
            ;;
        'shell pm path com.example.one')
            printf 'package:/data/app/one/base.apk\npackage:/data/app/one/split_config.xxhdpi.apk\r\n'
            ;;
        'shell pm path com.example.two')
            printf 'package:/data/app/two/base.apk\r\n'
            ;;
        'shell pm path '*)
            return 1
            ;;
        'pull '*)
            local src="${args#pull }"
            local dest="${src#* }"
            src="${src%% *}"
            printf '%s\n' "${src}" >>"${DEV}/pulled"
            [[ -f "${DEV}/fail_pull" ]] && return 1
            # A directory pull lands a directory; an APK pull lands a file.
            if [[ "${dest}" == */ ]]; then
                mkdir -p "${dest}"
            else
                mkdir -p "$(dirname "${dest}")"
                printf 'apk\n' >"${dest}"
            fi
            ;;
        'shell test -d /sdcard/'*)
            local d="${args##*/sdcard/}"
            [[ -f "${DEV}/nodir_${d}" ]] && return 1
            return 0
            ;;
        *'iname "*.kdbx"'*)
            cat "${DEV}/kdbx" 2>/dev/null || printf ''
            ;;
        'shell settings list '*)
            local ns="${args##* }"
            printf 'a_key=1\nb_key=2\r\n' | sed "s/^/${ns}_/"
            ;;
        *)
            printf 'unexpected adb_cmd: %s\n' "${args}" >&2
            return 1
            ;;
    esac
}

# shellcheck source=../backup_capture.sh
. "${SCRIPT_DIR}/../backup_capture.sh"

OUT="${TEST_TMPDIR}/out"
mkdir -p "${OUT}"
