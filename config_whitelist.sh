#!/bin/bash
# config_whitelist.sh -- the app allowlists: WHITELIST (day), NIGHT_WHITELIST
# (curfew) and the prefix lists. Split out of config.sh on 2026-09-18 for the
# 250-line cap; the content and its rationale comments are unchanged.
#
# Sourced by config.sh, which exports SCRIPT_DIR first. focus_policy.loader
# follows that include, so editing here is the same as editing config.sh.

# WHITELISTED APPS -- always enabled, even in focus mode.
# see docs/DOCS-policy-lists.md#whitelisted-apps

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
# com.facebook.orca (Messenger) was here until 2026-09-18. Removed so it is
# hidden at home and in the curfew like everything else; it stays visible
# away from home. Chat with friends moved to the PC, where messenger.com is
# allowed and the facebook.com feed is not.
# see docs/DOCS-policy-lists.md#why-comfacebookorca-left-the-day-list
# org.thoughtcrime.securesms: added 2026-08-29, night exemption added the same
# day. Corrected on 2026-08-29: this entry used to say the signal-bot runs as a
# LINKED DEVICE of this account and would become unre-linkable if Signal were
# hidden. That is wrong. The bot has its OWN registered number and is its own
# primary device -- GET /v1/devices for it returns a single device with id 1,
# and a linked device would be id 2 or higher. Hiding Signal here costs the bot
# nothing. It is whitelisted because it is kuhy's messaging app, in the same
# category as the fossify phone/messages/contacts entries above, and because
# adding the bot to a new group can only be done from the phone app.
# see docs/DOCS-policy-lists.md#why-orgthoughtcrimesecuresms-is-in-the-night-list
org.thoughtcrime.securesms

# --- Banking and identity (all device-paired over SMS; see docs) ---
pl.mbank
com.revolut.revolut
pl.infakt.infakt
pl.nask.mobywatel
com.kunzisoft.keepass.libre

# --- kuhy's own apps ---
com.kuhy.diet_guard_app
com.kuhy.dufs_client
com.kuhy.home_guard
com.kuhy.home_inventory
com.kuhy.lyricanki
com.kuhy.punchme
com.kuhy.restaurant_rater
com.kuhy.signalbot_remote
com.kuhy.untools
com.kuhy.wake_alarm_sync
com.kuhy.workout_app
# com.kuhy.workout_app.sandbox: the workout app's sandbox flavor -- its own
# package and data, so a whole workout can be driven on the phone without
# touching the real one. Deployed by phone_deploy.sh --flavor sandbox.
com.kuhy.workout_app.sandbox
dev.kuhy.todo

# --- Daily utility ---
com.google.android.calendar
com.google.android.deskclock
com.google.android.apps.maps
com.sosauce.cutecalc
com.ichi2.anki
com.metrolist.music
eu.kanade.tachiyomi.sy

# com.android.vending is NOT here and must not be re-added. Play is hidden at
# home, day and night, and shown only on the AWAY branch -- absence from this
# list AND from NIGHT_WHITELIST is what produces that. It is NOT in
# ALWAYS_BLOCKED_PACKAGES either, because infakt cannot start without Play:
# see docs/DOCS-policy-play-store.md#why-the-play-store-is-blocked-at-home-only
# NEVER put a dollar-sign reference or a double quote in this string, not even
# in a comment: both break the list silently.

# --- Workout tracking (always beneficial; must stay enabled to export runs) ---
org.runnerup
org.runnerup.free
"

# ALLOWED PACKAGE PREFIXES -- why prefixes, and how narrow to keep them:
# see docs/DOCS-policy-lists.md#allowed-package-prefixes

export ALLOWED_PREFIXES="
# Manga reader + its per-source extension apks.
eu.kanade.tachiyomi
# kuhy's own apps, day and night, including ones not written yet.
# see docs/DOCS-policy-lists.md#why-every-comkuhy-devkuhy-package-is-allowed-by-prefix
# NO TRAILING DOT: com.kuhy. matches nothing at all.
com.kuhy
dev.kuhy
"

# Prefixes that survive the curfew as well. Must be a subset of
# $ALLOWED_PREFIXES, mirroring the NIGHT_WHITELIST/WHITELIST subset rule.
export NIGHT_ALLOWED_PREFIXES="
eu.kanade.tachiyomi
# Same two prefixes as the day list: kuhy's apps stay reachable in the curfew.
com.kuhy
dev.kuhy
"

# NIGHT CURFEW WHITELIST -- what stays enabled at night and why, plus the
# prefix exception: see docs/DOCS-policy-lists.md#night-curfew-whitelist

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
com.metrolist.music
org.runnerup
org.runnerup.free
# dev.kuhy.todo: deliberate loosening of the night rule.
# see docs/DOCS-policy-lists.md#why-devkuhytodo-is-in-the-night-list
dev.kuhy.todo
# com.kuhy.punchme: same reason as dev.kuhy.todo -- keeps the deploy path
# open. see docs/DOCS-policy-lists.md#why-comkuhypunchme-is-in-the-night-list
com.kuhy.punchme
# com.kuhy.dufs_client: always-allowed file access, day and night.
# see docs/DOCS-policy-lists.md#why-comkuhydufs_client-is-in-the-night-list
com.kuhy.dufs_client
# com.kuhy.workout_app: was day-only, so the curfew hid it. Covered by the
# com.kuhy prefix above; listed here too so this stays a readable inventory.
com.kuhy.workout_app
# com.kuhy.workout_app.sandbox: same as above, for the sandbox flavor.
com.kuhy.workout_app.sandbox
# org.thoughtcrime.securesms: messaging, same category as the fossify phone,
# messages and contacts entries that are already here -- the curfew keeps you
# reachable, and Signal is where kuhy is actually reached.
# see docs/DOCS-policy-lists.md#why-orgthoughtcrimesecuresms-is-in-the-night-list
org.thoughtcrime.securesms
"
