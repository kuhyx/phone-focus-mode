#!/bin/bash

# ============================================================================
# Deploy focus-owner (com.kuhy.focus_owner, the Device Owner on the Pixel 6a)
# for real: the repo's `- deploy:` command (CLAUDE.md).
#
#   1. phone reachable, else exit 30 before anything changes;
#   2. `git pull --ff-only` the live checkout (~/src/phone-focus-mode): the
#      focus-mode whitelist phone_deploy reads lives there, and a dirty tree
#      fails the pull instead of being built;
#   3. release build + `adb install -r` via ~/.claude/scripts/phone_deploy.sh
#      (never uninstall, never pm clear; it fails closed on a signer change);
#   4. health: the installed versionCode rose and the app is still device
#      owner. Any failure exits non-zero (phone_deploy's own code if it failed).
#
# Idempotent: every run builds installed+1 and installs it over the old one.
# The release key is gitignored; a missing key.properties is a hard stop (a
# debug-signed build cannot replace a device owner without a factory reset).
# Env overrides (tests, phone swap): ADB_SERIAL, FOCUS_OWNER_LIVE_DIR,
# PHONE_DEPLOY.
# ============================================================================

set -euo pipefail

readonly PKG="com.kuhy.focus_owner"
readonly SERIAL="${ADB_SERIAL:-23181JEGR08034}"
readonly LIVE_DIR="${FOCUS_OWNER_LIVE_DIR:-$HOME/src/phone-focus-mode}"
readonly PHONE_DEPLOY="${PHONE_DEPLOY:-$HOME/.claude/scripts/phone_deploy.sh}"
readonly APP_DIR="$LIVE_DIR/focus-owner"
export ADB_SERIAL="$SERIAL"  # phone_deploy reads the same serial

die() {
    local code="$1"
    shift
    echo "deploy_owner: $*" >&2
    exit "$code"
}

version_code() {
    adb -s "$SERIAL" shell dumpsys package "$PKG" \
        | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1
}

main() {
    [[ "$(adb -s "$SERIAL" get-state 2>/dev/null)" == device ]] \
        || die 30 "phone $SERIAL unreachable"
    # pull --ff-only alone tolerates a dirty tree that does not conflict, and
    # would then build kuhy's uncommitted edits: refuse tracked changes first.
    [[ -z "$(git -C "$LIVE_DIR" status --porcelain --untracked-files=no)" ]] \
        || die 1 "$LIVE_DIR has uncommitted changes"
    git -C "$LIVE_DIR" pull --ff-only --quiet || die 1 "pull of $LIVE_DIR failed (diverged?)"
    [[ -f "$APP_DIR/android/key.properties" ]] \
        || die 36 "missing $APP_DIR/android/key.properties (copy ~/src/todo/android/key.properties)"

    local before after rc=0
    before="$(version_code)"
    "$PHONE_DEPLOY" "$APP_DIR" --release || rc=$?
    (( rc == 0 )) || die "$rc" "phone_deploy failed (exit $rc)"

    after="$(version_code)"
    if [[ -z "$after" ]] || (( after <= ${before:-0} )); then
        die 2 "versionCode did not rise (${before:-none} -> ${after:-none})"
    fi
    adb -s "$SERIAL" shell dpm list-owners | grep -q "$PKG" \
        || die 3 "$PKG is no longer device owner"
    echo "deploy_owner: ok $PKG versionCode ${before:-none} -> $after @ $(git -C "$LIVE_DIR" rev-parse --short HEAD)"
}

main "$@"
