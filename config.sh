#!/system/bin/sh
# Focus Mode Configuration. Set HOME_LAT/HOME_LON in config_secrets.sh before
# deploying (Google Maps: right-click your apartment -> coords).
#
# The lists below stay in THIS file: focus_policy's loader finds them by
# regex over config.sh's own text, so one moved into a config_*.sh sibling
# parses as empty with no error. Rationale lives in docs/policy-lists.md.

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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/config_secrets.sh"

# --- Radius in meters ---
export RADIUS=150

# --- Hysteresis buffer in meters (prevents rapid toggling at boundary) ---
export HYSTERESIS=30

# shellcheck source=config_paths.sh
. "$SCRIPT_DIR/config_paths.sh"

# NIGHT CURFEW (time-gated strict allow-list). Times are local 24h HHMM;
# the window wraps past midnight when START > END (e.g. 2300 -> 0500).
# see docs/policy-lists.md#night-curfew
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
# currently-installed copy (user installs once via Aurora/Play).
# The Pixel 6a's stock launcher. The previous value named the rooted
# Blackview's minimalist launcher, which is not installed here -- the exporter's
# launcher check caught it, which is the whole reason that check exists: hiding
# the launcher leaves the device with no home screen and no way back to the
# enforcer app.
export LAUNCHER_PACKAGE="com.google.android.apps.nexuslauncher"
# shellcheck source=config_launcher.sh
. "$SCRIPT_DIR/config_launcher.sh"

# WHITELISTED APPS -- always enabled, even in focus mode.
# see docs/policy-lists.md#whitelisted-apps

export WHITELIST="
# Rewritten 2026-08-11 for the unrooted Pixel 6a under Device Owner. The list
# it replaced described the rooted Blackview and named apps this phone does not
# have. Everything absent from this list is hidden while at home, including
# every browser -- so no link opens at all until you leave the geofence.

# --- Launcher (MUST be listed: hiding it leaves no home screen) ---
com.google.android.apps.nexuslauncher

# --- The enforcer and its VPN provider (hiding either is unrecoverable) ---
com.kuhy.focus_owner
com.celzero.bravedns
com.zaneschepke.wireguardautotunnel

# --- Phone, messaging, contacts (Polish UI: telefon / wiadomosci) ---
org.fossify.phone
org.fossify.messages
org.fossify.contacts
com.facebook.orca

# --- Banking and identity (all device-paired over SMS; see docs) ---
pl.mbank
com.revolut.revolut
pl.infakt.infakt
pl.nask.mobywatel
com.kunzisoft.keepass.libre

# --- kuhy's own apps ---
com.kuhy.diet_guard_app
com.kuhy.home_inventory
com.kuhy.untools
com.kuhy.wake_alarm_sync
com.kuhy.workout_app
dev.kuhy.todo

# --- Daily utility ---
com.google.android.calendar
com.google.android.deskclock
com.google.android.apps.maps
com.sosauce.cutecalc
com.ichi2.anki
com.metrolist.music
eu.kanade.tachiyomi.sy

# com.android.vending -- day only. NEVER put a dollar-sign reference or a
# double quote in this string, not even in a comment: both break the list
# silently. see docs/policy-lists.md#why-the-play-store-is-in-the-day-list
com.android.vending

# --- Workout tracking (always beneficial; must stay enabled to export runs) ---
org.runnerup
org.runnerup.free
"

# ALLOWED PACKAGE PREFIXES -- why prefixes, and how narrow to keep them:
# see docs/policy-lists.md#allowed-package-prefixes

export ALLOWED_PREFIXES="
# Manga reader + its per-source extension apks.
eu.kanade.tachiyomi
"

# Prefixes that survive the curfew as well. Must be a subset of
# $ALLOWED_PREFIXES, mirroring the NIGHT_WHITELIST/WHITELIST subset rule.
export NIGHT_ALLOWED_PREFIXES="
eu.kanade.tachiyomi
"

# NIGHT CURFEW WHITELIST -- what stays enabled at night and why, plus the
# prefix exception: see docs/policy-lists.md#night-curfew-whitelist

export NIGHT_WHITELIST="
# Curfew (23:00-05:00 at home) is strictly tighter than the day list: only what
# is needed to answer the phone, reach a bank, or handle an emergency. Rewritten
# 2026-08-11 alongside the day list.
com.kuhy.focus_owner
com.celzero.bravedns
com.google.android.apps.nexuslauncher
org.fossify.phone
org.fossify.messages
org.fossify.contacts
pl.mbank
com.revolut.revolut
pl.infakt.infakt
pl.nask.mobywatel
com.kunzisoft.keepass.libre
com.kuhy.wake_alarm_sync
com.google.android.deskclock
org.runnerup
org.runnerup.free
# dev.kuhy.todo: deliberate loosening of the night rule.
# see docs/policy-lists.md#why-devkuhytodo-is-in-the-night-list
dev.kuhy.todo
"

# ============================================================
# BLOCKED SYSTEM APPS
# System apps that should be disabled in focus mode.
# These are NOT covered by third-party package blocking.

# --- System / essential packages that must NEVER be disabled ---
# Prefix-matched. Why pl.infakt.infakt is here rather than allowlisted:
# see docs/policy-lists.md#system-packages-that-must-never-be-disabled
export SYSTEM_NEVER_DISABLE="
pl.infakt.infakt
# The always-on VPN provider. Hiding it is self-defeating in the worst way:
# it is the network-level YouTube block, and with DISALLOW_CONFIG_VPN pinned
# to a hidden package the device can lose general connectivity rather than
# just the filter. Must outrank every enforcement branch.
com.celzero.bravedns
com.android.launcher
com.android.launcher3
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
com.android.camera2
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
