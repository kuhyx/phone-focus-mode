#!/system/bin/sh
# Focus Mode Configuration. Set HOME_LAT/HOME_LON in config_secrets.sh before
# deploying (Google Maps: right-click your apartment -> coords).
#
# The lists below stay in THIS file: focus_policy's loader finds them by
# regex over config.sh's own text, so one moved into a config_*.sh sibling
# parses as empty with no error. Rationale lives in docs/DOCS-policy-lists.md.

# --- Home location (loaded from config_secrets.sh, not tracked by git) ---
SCRIPT_DIR="${FOCUS_MODE_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# If config.sh is sourced from an external wrapper (e.g. Magisk service.d),
# $0 points to the wrapper path rather than this file's directory. Fall back
# to the canonical runtime location if config_secrets is not alongside $0.
if [ ! -f "$SCRIPT_DIR/config_secrets.sh" ] && [ -f "/data/local/tmp/focus_mode/config_secrets.sh" ]; then
	SCRIPT_DIR="/data/local/tmp/focus_mode"
fi
# config_secrets.sh is deliberately untracked (it holds secrets, see
# .gitignore) and is created per-machine / pushed to the phone at deploy
# time. It does not exist in a clean checkout, so the linter cannot follow
# it there -- which is exactly what CI lints.
# Guarded so a clean clone -- and CI -- can source this file. The enforcers
# need real coordinates and will behave as "not home" without them, but the
# test suites pin HOME_LAT/HOME_LON themselves and must not require a secrets
# file that by design is never committed.
# shellcheck disable=SC1091
if [ -f "$SCRIPT_DIR/config_secrets.sh" ]; then
	. "$SCRIPT_DIR/config_secrets.sh"
fi

# --- Radius in meters ---
export RADIUS=150

# --- Hysteresis buffer in meters (prevents rapid toggling at boundary) ---
export HYSTERESIS=30

# shellcheck source=config_paths.sh
. "$SCRIPT_DIR/config_paths.sh"

# NIGHT CURFEW (time-gated strict allow-list). Times are local 24h HHMM;
# the window wraps past midnight when START > END (e.g. 2300 -> 0500).
# see docs/DOCS-policy-lists.md#night-curfew
export NIGHT_CURFEW_ENABLED=1
export NIGHT_CURFEW_START="2300"
export NIGHT_CURFEW_END="0500"

# shellcheck source=config_curfew.sh
. "$SCRIPT_DIR/config_curfew.sh"

# shellcheck source=config_tether.sh
. "$SCRIPT_DIR/config_tether.sh"

# Domains unblocked while a workout is in progress. Used by deploy.sh to
# generate $HOSTS_CANONICAL_WORKOUT (each line becomes a `0.0.0.0 <host>`
# match that is stripped from the canonical) and by focus_ctl.sh status.
# Comments and blank lines ignored. Keep entries lower-case.
export WORKOUT_UNBLOCK_DOMAINS="
youtube.com
www.youtube.com
m.youtube.com
youtu.be
youtubei.googleapis.com
youtube.googleapis.com
youtube-nocookie.com
www.youtube-nocookie.com
googlevideo.com
ytimg.com
i.ytimg.com
s.ytimg.com
yt3.ggpht.com
yt3.googleusercontent.com
i9.ytimg.com
"

# shellcheck source=config_dns.sh
. "$SCRIPT_DIR/config_dns.sh"

# Browsers to force-stop when the hosts file is updated or restored.
# Force-stopping clears the in-process DNS cache so the next launch
# consults the system resolver (which sees our /etc/hosts blocks).
# Packages not installed on the device are silently skipped.
export BROWSER_PACKAGES="
org.mozilla.fenix
com.android.chrome
"

# --- Launcher enforcer state (see launcher_enforcer.sh) ---
# Keeps Minimalist Phone installed and locked as the default HOME app.
# The APK is snapshotted by `deploy.sh --snapshot-launcher` from the
# currently-installed copy (user sideloads it once from the PC).
# The Pixel 6a's stock launcher. The previous value named the rooted
# Blackview's minimalist launcher, which is not installed here -- the exporter's
# launcher check caught it, which is the whole reason that check exists: hiding
# the launcher leaves the device with no home screen and no way back to the
# enforcer app.
export LAUNCHER_PACKAGE="com.google.android.apps.nexuslauncher"
# shellcheck source=config_launcher.sh
. "$SCRIPT_DIR/config_launcher.sh"
# shellcheck source=config_rethink.sh
. "$SCRIPT_DIR/config_rethink.sh"

# The three app allowlists (day, night, prefixes) live in their own file so
# this one stays under the 250-line cap. Sourced here so every shell consumer
# is unchanged; focus_policy.loader follows this include as well.
# shellcheck source=config_whitelist.sh
. "$SCRIPT_DIR/config_whitelist.sh"

# ============================================================
# BLOCKED SYSTEM APPS
# System apps that should be disabled in focus mode.
# These are NOT covered by third-party package blocking.

# --- System / essential packages that must NEVER be disabled ---
# Prefix-matched. Why pl.infakt.infakt is here rather than allowlisted:
# see docs/DOCS-policy-lists.md#system-packages-that-must-never-be-disabled
export SYSTEM_NEVER_DISABLE="
pl.infakt.infakt
# The always-on VPN provider. Hiding it is self-defeating in the worst way:
# it is the network-level YouTube block, and with DISALLOW_CONFIG_VPN pinned
# to a hidden package the device can lose general connectivity rather than
# just the filter. Must outrank every enforcement branch.
com.celzero.bravedns
com.android.launcher
com.android.settings
com.android.systemui
com.android.phone
com.android.dialer
com.android.contacts
com.android.mms
com.android.messaging
com.android.providers
com.android.inputmethod
com.android.shell
com.android.permissioncontroller
com.android.bluetooth
com.android.nfc
com.android.wifi
com.android.certinstaller
com.android.vpndialogs
com.android.se
com.android.emergency
com.android.camera
com.android.documentsui
com.android.externalstorage
com.android.keychain
com.android.location
com.android.networkstack
com.android.captiveportallogin
com.google.android.gms
com.google.android.gsf
com.google.android.ext.services
com.google.android.ext.shared
com.google.android.webview
com.google.android.trichromelibrary
com.google.android.inputmethod.latin
com.google.android.setupwizard
com.google.android.permissioncontroller
com.google.android.deskclock
com.google.android.dialer
com.google.android.contacts
com.google.android.apps.messaging
android
com.mediatek
com.qualcomm
"
