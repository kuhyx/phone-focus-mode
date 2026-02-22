#!/system/bin/sh
# ============================================================
# Focus Mode Configuration
# ============================================================
# IMPORTANT: You MUST set HOME_LAT and HOME_LON to your
# apartment's coordinates before deploying.
# Get them from Google Maps: right-click your apartment → coords
# ============================================================

# --- Home location (Warsaw, auto-detected via GPS on 2026-02-22) ---
export HOME_LAT="REDACTED_LAT"
export HOME_LON="REDACTED_LON"

# --- Radius in meters ---
export RADIUS=500

# --- Hysteresis buffer in meters (prevents rapid toggling at boundary) ---
export HYSTERESIS=50

# --- Location check interval in seconds ---
export CHECK_INTERVAL=60

# --- Fail-safe: if location unavailable for this many consecutive checks,
#     switch to unrestricted mode to avoid locking user out ---
export MAX_LOCATION_FAILS=5

# --- Log file ---
export LOG_FILE="/data/local/tmp/focus_mode/focus_mode.log"
export LOG_MAX_LINES=500

# --- State file (tracks which apps were disabled by focus mode) ---
STATE_DIR="/data/local/tmp/focus_mode"
export DISABLED_APPS_FILE="$STATE_DIR/disabled_by_focus.txt"
export MODE_FILE="$STATE_DIR/current_mode.txt"

# ============================================================
# WHITELISTED APPS
# These apps will ALWAYS remain enabled, even in focus mode.
# Package names verified against installed packages on 2026-02-22.
# ============================================================

export WHITELIST="
# --- User-requested productive apps ---
com.stronglifts.app
com.ichi2.anki
com.metrolist.music
com.kuhy.pomodoro_app

# --- Google system apps (add by name even though they show as system) ---
com.google.android.apps.maps
com.google.android.calendar

# --- Notes & productivity ---
net.cozic.joplin

# --- Navigation & transit (needed when going out) ---
net.osmand
de.schildbach.oeffi
com.kolejeslaskie.mss

# --- Banking (must always work) ---
pl.mbank
pl.pkobp.iko

# --- Security & root tools (must always work) ---
com.topjohnwu.magisk
moe.shizuku.privileged.api
me.phh.superuser
com.beemdevelopment.aegis
com.azure.authenticator
oracle.idm.mobile.authenticator
com.kunzisoft.keepass.libre

# --- Email & communication ---
com.microsoft.office.outlook
com.google.android.gm
ch.protonmail.android
com.microsoft.teams
"

# --- System / essential packages that must NEVER be disabled ---
# These are matched as prefixes (startswith).
# You generally don't need to edit this list.
export SYSTEM_NEVER_DISABLE="
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
com.android.packageinstaller
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
com.google.android.packageinstaller
com.google.android.permissioncontroller
com.google.android.deskclock
com.google.android.dialer
com.google.android.contacts
com.google.android.apps.messaging
android
com.mediatek
com.qualcomm
"
