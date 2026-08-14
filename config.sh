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

# ============================================================
# NIGHT CURFEW (time-gated strict allow-list)
# ============================================================
# When focus mode is ON (i.e. you are at home) AND the local clock is inside
# the curfew window, the daemon switches from the permissive $WHITELIST to the
# strict $NIGHT_WHITELIST: every app not on that short list is disabled. This
# is the "stop using the phone after 23:00 at home" layer. The companion
# enforcer (curfew_enforcer.sh) adds grayscale + DND + an optional per-UID
# network allow-list on top. Times are local 24h "HHMM"; the window wraps past
# midnight when START > END (e.g. 2300 -> 0500).
export NIGHT_CURFEW_ENABLED=1
export NIGHT_CURFEW_START="2300"
export NIGHT_CURFEW_END="0500"
# Escape hatch: if this file exists, curfew is suspended (treated as daytime)
# everywhere — app list, grayscale, DND and network. Delete it to re-arm.
# WHO CAN CREATE IT (recovery paths, strongest lock first):
#   * `focus_ctl.sh curfew-off` over ADB from the PC  (always available daily).
#   * The Magisk boot emergency-disable file ($FOCUS_BOOT_EMERGENCY_DISABLE_FILE)
#     stops the whole stack at next boot.
#   * A root file-manager/terminal ONLY IF one is added to $NIGHT_WHITELIST.
#     None is whitelisted by default — that is deliberate ("hard to turn off").
# The active-IME guard in focus_daemon.sh keeps the keyboard alive so whichever
# path you choose is always typable. If you want a true no-PC 2am opt-out,
# whitelist a root terminal at night (see NIGHT_WHITELIST) or wire a companion-
# app button. Until then, recovery is PC/ADB-based by design.
export CURFEW_OVERRIDE_FILE="$STATE_DIR/curfew_override"

# --- Curfew enforcer (grayscale + DND + per-UID network allow-list) ---
# See curfew_enforcer.sh. Always-on like dns_enforcer, but only ACTS while the
# curfew window is open AND focus mode is ON. Re-applies every interval so a
# manual toggle in Settings snaps back ("hard to turn off"). NOTE: snap-back is
# the realistic lock; true impossibility would mean blocking the Settings app,
# which risks system instability, so we deliberately do not.
export CURFEW_ENFORCER_INTERVAL=5
export CURFEW_ENFORCER_LOG="$STATE_DIR/curfew_enforcer.log"
export CURFEW_ENFORCER_STATE="$STATE_DIR/curfew_applied"
# Grayscale: force the display to monochrome via the accessibility daltonizer.
export CURFEW_GRAYSCALE_ENABLED=1
# DND: force Do-Not-Disturb to alarms-only so notifications stop pulling you in
# while the morning alarm still rings.
export CURFEW_DND_ENABLED=1
# Per-UID internet allow-list. DEFAULT OFF: highest-risk layer, must be proven
# on-device (`focus_ctl.sh curfew-test-on`) before it is trusted to fire
# unattended at 23:00. When on, only $NIGHT_WHITELIST app UIDs (plus
# root/system/shell + DNS) get network; every other app is cut off. It is also
# largely redundant with the app-disable layer, so leaving it off is safe.
export CURFEW_NET_ENABLED=1
export CURFEW_NET_IPT_CHAIN="FOCUS_CURFEW_NET"
# Android's netd periodically reasserts the whole `filter` table via
# iptables-restore, which atomically erases our custom chain (proven on-device:
# the chain vanishes ~every 5s). The main enforcer tick (5s) rebuilds it but
# leaves up-to-5s leak windows. This watchdog re-pins the chain every
# CURFEW_NET_REASSERT_INTERVAL seconds *from a cached UID list* (no pm fork).
# A 1s interval was measured on-device to peg netd at ~30% CPU continuously
# (an `iptables -L` fork every second, all night), overheating the phone -
# throttled to 15s (matches HOSTS_CHECK_INTERVAL/LAUNCHER_CHECK_INTERVAL
# pacing) as a deliberate tradeoff: leak window grows from <=1s to <=15s.
# The proper fix is netd's own per-UID firewall (ndc/eBPF), tracked as a
# follow-up; this remains an interim stopgap either way.
export CURFEW_NET_REASSERT_INTERVAL=15
export CURFEW_NET_UID_CACHE="$STATE_DIR/curfew_net_uids.txt"
# Manual test toggle: `focus_ctl.sh curfew-test-on` writes this file to force
# curfew ACTIVE regardless of clock, so the whole stack can be validated during
# the day. `curfew-test-off` removes it.
export CURFEW_FORCE_FILE="$STATE_DIR/curfew_force_on"

# ============================================================
# HOTSPOT / TETHERING BLOCK (closes the "second phone" bypass)
# ============================================================
# The hosts file, dns_enforcer and the curfew net layer all only touch this
# phone's OWN traffic (system resolver + OUTPUT chain). A tethered second
# device's packets are FORWARDed + NAT'd through us on an unfiltered path, so
# it browses freely on our mobile data. tether_enforcer.sh closes that hole.
# Always-on like dns_enforcer, but only ACTS while focus mode is ON (i.e. you
# are at home: $MODE_FILE == "focus") OR the force-test file is present. Covers
# WiFi, USB and Bluetooth tethering, since all of it traverses FORWARD.
export TETHER_ENFORCER_ENABLED=1
export TETHER_CHECK_INTERVAL=5
export TETHER_LOG="$STATE_DIR/tether_enforcer.log"
export TETHER_ENFORCER_STATE="$STATE_DIR/tether_applied"
# Lever 1: disable Android's hardware/BPF tether offload so forwarded traffic
# is actually seen by netfilter (otherwise the FORWARD rule can be silently
# skipped). AOSP global key Settings.Global.TETHER_OFFLOAD_DISABLED; 1=disabled.
# Snapshotted on entry and restored on exit so we never clobber a user value.
export TETHER_OFFLOAD_KEY="tether_offload_disabled"
export TETHER_OFFLOAD_SNAP="$STATE_DIR/tether_offload.snap"
# Lever 2: blanket REJECT of the FORWARD chain (both iptables + ip6tables).
# Re-pinned only when tampered (chain_intact gate, like dns_enforcer) so we do
# not fork an `iptables -L` every second — that pegged netd + overheated the
# phone during curfew-net tuning (see CURFEW_NET_REASSERT_INTERVAL note above).
export TETHER_IPT_CHAIN="FOCUS_TETHER_BLOCK"
# Lever 3 (best-effort, WiFi only): actively stop a running softAP each tick so
# the hotspot toggle visibly flips off. Version-gated (cmd wifi stop-softap is
# Android 11+). The FORWARD block remains the version-independent catch-all.
export TETHER_STOP_SOFTAP_ENABLED=1
# Escape hatches (mirrors the curfew override/force pair):
#   tether_override -> suspend the block without stopping the daemon.
#   tether_force_on -> force the block ACTIVE regardless of location (daytime
#                      on-device validation via `focus_ctl.sh tether-test-on`).
export TETHER_OVERRIDE_FILE="$STATE_DIR/tether_override"
export TETHER_FORCE_FILE="$STATE_DIR/tether_force_on"

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
# Workout-variant canonical: same content as $HOSTS_CANONICAL but with all
# YouTube-related domain blocks removed. hosts_enforcer.sh switches to this
# variant when $WORKOUT_ACTIVE_FILE contains "1" (StrongLifts workout in
# progress) and switches back when it contains "0" or is missing.
export HOSTS_CANONICAL_WORKOUT="$STATE_DIR/hosts.canonical.workout"
export HOSTS_SHA_FILE_WORKOUT="$STATE_DIR/hosts.sha256.workout"
# Magisk Systemless Hosts module path. The enforcer keeps this in sync with
# the currently-active canonical so a fresh boot sees the right hosts file.
export HOSTS_MAGISK_MODULE_FILE="/data/adb/modules/hosts/system/etc/hosts"

# --- Workout detector (see workout_detector.sh) ---
# Polls the StrongLifts SQLite DB to determine whether a workout is in
# progress. A workout is "in progress" iff there is at least one row in
# `workouts` with start>0 AND (finish IS NULL OR finish=0). While true,
# YouTube is unblocked at the hosts level (see HOSTS_CANONICAL_WORKOUT).
export WORKOUT_DETECTOR_INTERVAL=10
export WORKOUT_ACTIVE_FILE="$STATE_DIR/workout_active"
export WORKOUT_DETECTOR_LOG="$STATE_DIR/workout_detector.log"
# Static aarch64 sqlite3 binary pushed by deploy.sh. Built from the SQLite
# amalgamation against the Android NDK; ~1.6 MB. Stored outside the repo at
# ../testsAndMisc_binaries/phone_focus_mode/sqlite3 per binary-files policy.
export WORKOUT_SQLITE3_BIN="/data/local/tmp/focus_mode/sqlite3"
export WORKOUT_DB_PATH="/data/data/com.stronglifts.app/databases/StrongLifts-Database-3"
# StrongLifts package — must be in $WHITELIST so its DB stays writable while
# focus mode is enforcing. Used here only for status/log clarity.
export WORKOUT_TRIGGER_PACKAGE="com.stronglifts.app"
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

# --- DNS enforcer state (see dns_enforcer.sh) ---
# The hosts file is only consulted by the *system* resolver. Apps using
# DNS-over-HTTPS (DoH, e.g. Chrome's built-in secure DNS) or DNS-over-TLS
# (DoT, e.g. Android 9+ Private DNS "opportunistic" mode) bypass it.
# The DNS enforcer pins Private DNS to OFF and blocks well-known DoH/DoT
# endpoints so lookups fall back to the system resolver -> hosts file.
export DNS_CHECK_INTERVAL=20
export DNS_LOG="$STATE_DIR/dns_enforcer.log"
# --- Trusted DoT resolver (opt-in, empty = old behaviour) ---
# Set this to the hostname of a DoT resolver you control, and the enforcer
# switches from "no DoT at all" to "only YOUR DoT". Two things change:
#   1. an ACCEPT for that resolver's IPs is inserted BEFORE the blanket
#      853 REJECT, so the connection survives;
#   2. private_dns_mode is pinned to "hostname" with this specifier, instead
#      of being forced off -- so the phone cannot silently fall back to a
#      resolver that does not filter.
# Leave EMPTY to keep the original behaviour (Private DNS forced off, all
# 853 rejected). Do not point this at a public resolver: the whole point is
# that the resolver applies your blocklist. See python_pkg/focus_policy.
export DNS_TRUSTED_DOT_HOST=""
# Where to resolve DNS_TRUSTED_DOT_HOST when Private DNS is pinned to it.
# Chicken-and-egg: the resolver's own name must resolve without using it.
# Space-separated IPv4/IPv6 literals; leave empty to resolve at runtime.
export DNS_TRUSTED_DOT_IPS=""
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
104.16.248.249
104.16.249.249
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
2606:4700::6810:f8f9
2606:4700::6810:f9f9
"

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
export LAUNCHER_APK="/data/adb/focus_mode/minimalist_launcher.apk"
export LAUNCHER_SHA_FILE="/data/adb/focus_mode/minimalist_launcher.sha256"
# Captured home-activity component (package/.Activity). Saved by
# --snapshot-launcher so the enforcer knows which component to pin as HOME.
export LAUNCHER_ACTIVITY_FILE="/data/adb/focus_mode/minimalist_launcher.activity"
# Competing launchers to disable so the "pick a launcher" dialog has
# nothing else to offer. Matched exactly; add more with `focus_ctl.sh
# launcher-disable-other <pkg>`.
# com.blackview.launcher is intentionally excluded from LAUNCHER_COMPETITORS:
# Blackview embeds com.android.quickstep.RecentsActivity inside this APK,
# so disabling it kills the system-wide "swipe up for recent apps" gesture.
export LAUNCHER_COMPETITORS="
com.android.launcher
com.android.launcher3
com.google.android.apps.nexuslauncher
"
export LAUNCHER_CHECK_INTERVAL=15
export LAUNCHER_LOG="$STATE_DIR/launcher_enforcer.log"

# ============================================================
# WHITELISTED APPS
# These apps will ALWAYS remain enabled, even in focus mode.
# Package names verified against installed packages on 2026-02-22.
# ============================================================

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

# --- App store (day only; deliberately absent from the night list) ---
# NB: never write a dollar-sign variable reference inside this list. WHITELIST
# is a double-quoted string, so even a comment line expands, and deploy.sh
# runs under set -u, where an undefined name aborts the whole deploy. A
# reference to the night list sat here and did exactly that (it is defined
# below this point, so it was still unset), blocking every focus-mode deploy.
# Same rule for double quotes: one in a comment ends the string early.
# infakt cannot be installed or updated without Play, and it is device-paired
# to a bank, so losing the ability to update it strands a re-authentication
# chain. This does NOT reopen YouTube: the sweep is default-deny for
# third-party packages, so anything installed from Play is hidden on the next
# at-home pass, and the always-blocked set (YouTube, Chrome) is never restored
# by the AWAY branch either. Reinstalling YouTube from Play is UNTESTED as a
# bypass:
# the sweep would re-hide it within one pass regardless, but treat the claim
# that Play cannot resurrect a blocked app as unverified until someone tries.
# NOTE: never use a double-quote character anywhere inside these export
# blocks, not even in a comment. The policy loader matches a quoted value up
# to the next quote, so one stray quote terminates the string early and
# silently truncates the allowlist -- which drops apps with no error at all.
com.android.vending

# --- Workout tracking (always beneficial; must stay enabled to export runs) ---
org.runnerup
org.runnerup.free
"

# ============================================================
# ALLOWED PACKAGE PREFIXES
# Matched as prefixes on whole labels, exactly like $SYSTEM_NEVER_DISABLE:
# "eu.kanade.tachiyomi" covers "eu.kanade.tachiyomi.sy" and
# "eu.kanade.tachiyomi.extension.all.mangadex", but not
# "eu.kanade.tachiyomisomething".
#
# This exists because Tachiyomi installs every source as its OWN apk. Listing
# them individually means each newly installed extension is invisible until
# this file is edited and the policy regenerated -- a recurring chore that
# looks exactly like a bug from the phone.
#
# Weaker than the exact list by construction: a prefix allows packages that do
# not exist yet. Keep the prefixes narrow and vendor-specific for that reason.
# ============================================================

export ALLOWED_PREFIXES="
# Manga reader + its per-source extension apks.
eu.kanade.tachiyomi
"

# Prefixes that survive the curfew as well. Must be a subset of
# $ALLOWED_PREFIXES, mirroring the NIGHT_WHITELIST/WHITELIST subset rule.
export NIGHT_ALLOWED_PREFIXES="
eu.kanade.tachiyomi
"

# ============================================================
# NIGHT CURFEW WHITELIST
# These are the ONLY third-party apps that stay enabled during the curfew
# window (see NIGHT_CURFEW_* above). Everything else in $WHITELIST — browsers,
# social, messaging, email, stores, transit — is disabled.
# Allow-list by design: when in doubt, leave it OUT.
#
# EXCEPTION: $NIGHT_ALLOWED_PREFIXES is applied on top of this list, and it
# currently carries "eu.kanade.tachiyomi" — so manga IS available during the
# curfew, deliberately (chosen 2026-08-14). This paragraph used to say manga
# was disabled at night; it was true until that change. Do not "restore" it
# without also emptying $NIGHT_ALLOWED_PREFIXES, or the comment and the
# behaviour disagree again.
#
# Parsed exactly like $WHITELIST (one package per line, '#' comments ignored).
# The sysprotect prefixes ($SYSTEM_NEVER_DISABLE) and the default-handler guard
# (dialer/SMS/home/browser/IME) still apply on TOP of this list, so the active
# keyboard and core system apps are protected even if omitted here.
# ============================================================

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
# Capture-only notes app. Added 2026-08-14 after a curfew-window deploy
# installed it and the enforcer removed the package ~80ms later: it was in
# the day list but not here, so any build shipped after 23:00 was silently
# uninstalled. This is a deliberate loosening of the answer-the-phone /
# reach-a-bank / handle-an-emergency rule above -- writing an idea down at
# night is the one thing this app does, and losing the deploy path for six
# hours a day cost more than the distraction risk.
dev.kuhy.todo
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
# protection → recovery → factory wipe (confirmed on BL9000).
#
# System/distraction apps are enforced via DNS+iptables in dns_enforcer.sh
# instead of persistent package-disable state.
"

# --- System / essential packages that must NEVER be disabled ---
# These are matched as prefixes (startswith).
# You generally don't need to edit this list.
#
# pl.infakt.infakt is the one non-system entry. Allowlisting it is weaker:
# that depends on it staying in BOTH the day and night lists, and dropping it
# from either would silently make it hideable. It is device-paired to a bank
# over SMS, so losing access to it strands the same re-authentication chain a
# hidden Messages app would. isAllowed() checks this list first, before the
# curfew split, so it holds under every condition.
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
