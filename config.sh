#!/system/bin/sh
# ============================================================
# Focus Mode Configuration
# ============================================================
# IMPORTANT: You MUST set HOME_LAT and HOME_LON in config_secrets.sh
# before deploying.
# Get them from Google Maps: right-click your apartment → coords
# ============================================================

# --- Home location (loaded from config_secrets.sh, not tracked by git) ---
SCRIPT_DIR="${FOCUS_MODE_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# If config.sh is sourced from an external wrapper (e.g. Magisk service.d),
# $0 points to the wrapper path rather than this file's directory. Fall back
# to the canonical runtime location if config_secrets is not alongside $0.
if [ ! -f "$SCRIPT_DIR/config_secrets.sh" ] && [ -f "/data/local/tmp/focus_mode/config_secrets.sh" ]; then
	SCRIPT_DIR="/data/local/tmp/focus_mode"
fi
. "$SCRIPT_DIR/config_secrets.sh"

# --- Radius in meters ---
export RADIUS=150

# --- Hysteresis buffer in meters (prevents rapid toggling at boundary) ---
export HYSTERESIS=30

# --- Location check interval in seconds ---
# When focus mode is ON (at home): check very frequently for near-instant
# detection of leaving home (phone is charging anyway).
# When focus mode is OFF (away): check less often to save battery.
export CHECK_INTERVAL_FOCUS=10
export CHECK_INTERVAL_NORMAL=120

# --- Log file ---
export LOG_FILE="/data/local/tmp/focus_mode/focus_mode.log"
export LOG_MAX_LINES=500

# --- State file (tracks which apps were disabled by focus mode) ---
STATE_DIR="/data/local/tmp/focus_mode"
export DISABLED_APPS_FILE="$STATE_DIR/disabled_by_focus.txt"
export MODE_FILE="$STATE_DIR/current_mode.txt"
# Status snapshot consumed by the companion notification app (focus_status_app).
# Written by focus_daemon.sh every loop iteration. Chmod 644 so apps can read.
export STATUS_FILE="$STATE_DIR/status.json"
# Trigger file: companion app (or user) touches this to request an immediate
# re-check. focus_daemon.sh polls for it and skips the remainder of its sleep.
export RECHECK_TRIGGER="$STATE_DIR/trigger_recheck"

# --- Boot-time autostart safety gate ---
# Critical safety default: do NOT auto-start focus daemons at boot unless
# explicitly enabled. This avoids device instability during early boot on
# vendor ROMs after resets/updates.
# Late-auto mode: boot stack starts only after Android reports boot complete.
export FOCUS_BOOT_AUTOSTART=1
# Extra grace period after sys.boot_completed. Keep at or below 10 seconds.
export FOCUS_BOOT_DELAY_SECONDS=10
# Hard timeout while waiting for sys.boot_completed in Magisk service script.
export FOCUS_BOOT_WAIT_MAX_SECONDS=180
# Emergency kill switch file: if this marker exists on phone, boot autostart
# is skipped entirely for this boot. Create with:
#   adb shell su -c 'touch /data/local/tmp/focus_mode/disable_boot_autostart'
export FOCUS_BOOT_EMERGENCY_DISABLE_FILE="$STATE_DIR/disable_boot_autostart"

# --- Hosts enforcer state (see hosts_enforcer.sh) ---
# Canonical hosts file pushed by deploy.sh. The enforcer bind-mounts this
# over /system/etc/hosts and restores any tampering.
export HOSTS_CANONICAL="$STATE_DIR/hosts.canonical"
export HOSTS_TARGET="/system/etc/hosts"
export HOSTS_SHA_FILE="$STATE_DIR/hosts.sha256"
export HOSTS_CHECK_INTERVAL=15
export HOSTS_LOG="$STATE_DIR/hosts_enforcer.log"

# --- DNS enforcer state (see dns_enforcer.sh) ---
# The hosts file is only consulted by the *system* resolver. Apps using
# DNS-over-HTTPS (DoH, e.g. Chrome's built-in secure DNS) or DNS-over-TLS
# (DoT, e.g. Android 9+ Private DNS "opportunistic" mode) bypass it.
# The DNS enforcer pins Private DNS to OFF and blocks well-known DoH/DoT
# endpoints so lookups fall back to the system resolver -> hosts file.
export DNS_CHECK_INTERVAL=20
export DNS_LOG="$STATE_DIR/dns_enforcer.log"
# iptables chain used exclusively by us; we flush+refill it every check.
export DNS_IPT_CHAIN="FOCUS_DNS_BLOCK"
# DoH/DoT endpoints to DROP. Well-known public resolvers used by browsers
# and OS when Private DNS is enabled. Updating this list is cheap — just
# edit and redeploy.
export DNS_DOH_HOSTS="
dns.google
dns64.dns.google
dns.quad9.net
dns.cloudflare.com
one.one.one.one
cloudflare-dns.com
mozilla.cloudflare-dns.com
chrome.cloudflare-dns.com
dns.nextdns.io
doh.opendns.com
dns.adguard-dns.com
dns.adguard.com
dns.controld.com
"
# IPv4/IPv6 literals used by DoT (port 853) and DoH (port 443). Anything
# not already resolved via /etc/hosts still needs literal-IP blocks.
export DNS_DOH_IPV4="
8.8.8.8
8.8.4.4
1.1.1.1
1.0.0.1
9.9.9.9
149.112.112.112
94.140.14.14
94.140.15.15
208.67.222.222
208.67.220.220
45.90.28.0
45.90.30.0
"
export DNS_DOH_IPV6="
2001:4860:4860::8888
2001:4860:4860::8844
2606:4700:4700::1111
2606:4700:4700::1001
2620:fe::fe
2620:fe::9
2a10:50c0::ad1:ff
2a10:50c0::ad2:ff
"
# Additional content hosts to block at the firewall layer. This is a fallback
# for ROMs where /etc/hosts cannot be mounted (read-only partitions with no
# hosts inode). dns_enforcer.sh resolves these hostnames periodically and
# rejects traffic to their current endpoints on ports 80/443.
export DNS_BLOCK_HOSTS="
youtube.com
www.youtube.com
m.youtube.com
youtu.be
youtubei.googleapis.com
www.youtube-nocookie.com
googlevideo.com
ytimg.com
"

# Block network for selected distraction/system apps at firewall level by UID.
# This avoids pm disable/uninstall on system packages (which can destabilize
# boot on some vendor ROMs) while still making the apps effectively unusable.
#
# DNS_BLOCK_PACKAGES_ALWAYS: blocked at all times. Use for hard-distraction
#   apps that should never have web access (YouTube app, YouTube Music, the
#   stock browser). Hosts-file blocking handles their *content*; the UID rule
#   keeps them from using DoH/QUIC fallbacks.
# DNS_BLOCK_PACKAGES_FOCUS_ONLY: blocked only while focus mode is active
#   (current_mode.txt = focus). Use for apps that have legitimate use outside
#   focus mode (Play Store for installing apps you want, package installer).
export DNS_BLOCK_PACKAGES_ALWAYS="
com.google.android.youtube
com.google.android.apps.youtube.music
com.android.chrome
"
export DNS_BLOCK_PACKAGES_FOCUS_ONLY="
com.android.vending
"
# Backwards-compat: code paths still referencing DNS_BLOCK_PACKAGES treat it
# as the always-blocked list.
export DNS_BLOCK_PACKAGES="$DNS_BLOCK_PACKAGES_ALWAYS"

# --- Launcher enforcer state (see launcher_enforcer.sh) ---
# Keeps Minimalist Phone installed and locked as the default HOME app.
# The APK is snapshotted by `deploy.sh --snapshot-launcher` from the
# currently-installed copy (user installs once via Aurora/Play).
export LAUNCHER_PACKAGE="com.qqlabs.minimalistlauncher"
export LAUNCHER_APK="$STATE_DIR/minimalist_launcher.apk"
export LAUNCHER_SHA_FILE="$STATE_DIR/minimalist_launcher.sha256"
# Captured home-activity component (package/.Activity). Saved by
# --snapshot-launcher so the enforcer knows which component to pin as HOME.
export LAUNCHER_ACTIVITY_FILE="$STATE_DIR/minimalist_launcher.activity"
# Competing launchers to disable so the "pick a launcher" dialog has
# nothing else to offer. Matched exactly; add more with `focus_ctl.sh
# launcher-disable-other <pkg>`.
export LAUNCHER_COMPETITORS="
com.blackview.launcher
com.blackview.launcher.overlay.framework
com.android.launcher
com.android.launcher3
com.google.android.apps.nexuslauncher
"
export LAUNCHER_CHECK_INTERVAL=15
export LAUNCHER_LOG="$STATE_DIR/launcher_enforcer.log"
# Boot-time launcher enforcement is intentionally opt-in. Starting it from
# Magisk service.d can strand the phone on a broken HOME configuration if the
# snapshot is stale or the launcher update changed components. Keep this off by
# default and only enable it after verifying the launcher snapshot is healthy.
export LAUNCHER_BOOT_AUTOSTART=0

# ============================================================
# WHITELISTED APPS
# These apps will ALWAYS remain enabled, even in focus mode.
# Package names verified against installed packages on 2026-02-22.
# ============================================================

export WHITELIST="
# --- Protected launcher (MUST be whitelisted - see launcher_enforcer.sh) ---
# The focus daemon disables every 3rd-party app not in this list. If the
# launcher is not listed, focus mode will disable it and the home screen
# becomes blank. Keep this in sync with LAUNCHER_PACKAGE above.
com.qqlabs.minimalistlauncher

# --- Companion status-notification app (MUST be whitelisted) ---
# Provides the persistent focus-mode notification + Re-check-now button.
# If disabled, the status notification vanishes and the recheck action
# stops working. See phone_focus_mode/focus_status_app/.
com.kuhy.focusstatus

# --- User-requested productive apps ---
com.stronglifts.app
com.ichi2.anki
com.metrolist.music
com.kuhy.pomodoro_app
com.kuhy.horatio

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

# --- App installation alternative (keep visible in focus mode) ---
com.aurora.store

# --- Manga reader ---
eu.kanade.tachiyomi.sy

# --- Development ---
com.github.android

# --- Media / podcasts ---
ac.mdiq.podcini.X
is.xyz.mpv

# --- Bible study ---
net.bible.android.activity
com.schwegelbin.openbible

# --- Transit (Polish public transport) ---
pkp.ic.eicmobile
pl.plksa.portalpasazera

# --- Telco ---
pl.orange.mojeorange

# --- Fitness ---
org.runnerup

# --- Bill splitting ---
com.jwang123.splitbills
com.Splitwise.SplitwiseMobile

# --- Smart home ---
com.xiaomi.smarthome
"

# ============================================================
# BLOCKED SYSTEM APPS
# System apps that should be disabled in focus mode.
# These are NOT covered by third-party package blocking.
# ============================================================

export BLOCKED_SYSTEM_APPS="
# *** INTENTIONALLY EMPTY ***
#
# pm disable-user state persists across reboots. Android always kills daemon
# processes with SIGKILL during shutdown, bypassing the shell cleanup trap.
# Any system package left disabled across a reboot can trigger MTK bootloop
# protection → recovery → factory wipe (confirmed: caused 3 wipes on BL9000).
#
# System apps (Chrome, YouTube, Play Store, etc.) are enforced via
# DNS+iptables in dns_enforcer.sh instead — that layer is stateless and
# requires no cleanup on reboot.
#
# Only user-installed 3rd-party apps (pm list packages -3) are safe for
# pm disable-user because the MTK bootloop trigger only fires on missing or
# disabled ROM/system components, not on user-installed packages.
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
