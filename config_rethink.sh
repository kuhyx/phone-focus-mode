#!/bin/bash
# config_rethink.sh -- domains pushed into RethinkDNS's universal domain rules.
#
# Sourced by config.sh. Consumed by `python3 -m rethink_rules`, which drives
# the RethinkDNS UI over adb/uiautomator because the app has no import path
# for custom rules (celzero/rethink-app#237, still open 2026-09-14).
#
# This is the SOFT web layer on the unrooted Pixel 6a: RethinkDNS rules can be
# switched off from inside the app in a few taps, and no device-owner API can
# stop that. It exists to add friction to the browser path when away from
# home, where every browser is visible. At home and in the curfew the browsers
# are hidden, which is what actually closes the web.
#
# Each entry produces TWO rules, because Rethink's semantics split them:
# `example.com` blocks only the bare host and `*.example.com` only its
# subdomains (rethinkdns.com/faq). List bare registrable domains only.
#
# NEVER put a dollar-sign reference or a double quote in this string, not even
# in a comment: both break the list silently.
export RETHINK_BLOCK_DOMAINS="
# --- Food delivery: mirrors the PC list in hosts-blocker/custom_entries.hosts.
# The apps themselves are hidden everywhere by ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES
# in focus_policy/export.py; this is the browser path.
pyszne.pl
glovoapp.com
glovo.com
wolt.com
woltwojta.pl
bolt.eu
uber.com
ubereats.com
ubereats.pl
deliveroo.com
foodpanda.com
# --- Facebook feed and Messenger WEB clients (added 2026-09-18).
# Only the web hosts, deliberately: the Messenger APP stays usable away from
# home (config.sh WHITELIST rationale) and it talks to graph./edge-mqtt./
# b-api.facebook.com, none of which is listed. A bare facebook.com entry here
# would kill the app too.
messenger.com
"

# Hosts blocked as exact entries only, no wildcard twin: these ARE the
# subdomains, and a wildcard on them would be a no-op.
export RETHINK_BLOCK_EXACT_HOSTS="
www.facebook.com
m.facebook.com
web.facebook.com
mbasic.facebook.com
"
