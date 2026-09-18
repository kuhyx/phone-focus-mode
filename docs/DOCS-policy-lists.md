# Policy list rationale

Prose moved out of `phone_focus_mode/config.sh` to keep that file under
the repo's 250-line cap. The lists themselves stay in `config.sh` and
must: `python_pkg/focus_policy/loader.py` finds them by regex-scanning
that file's text alone, so a list moved elsewhere silently parses as
empty.

## Allowed Package Prefixes

ALLOWED PACKAGE PREFIXES
Matched as prefixes on whole labels, exactly like $SYSTEM_NEVER_DISABLE:
"eu.kanade.tachiyomi" covers "eu.kanade.tachiyomi.sy" and
"eu.kanade.tachiyomi.extension.all.mangadex", but not
"eu.kanade.tachiyomisomething".
This exists because Tachiyomi installs every source as its OWN apk. Listing
them individually means each newly installed extension is invisible until
this file is edited and the policy regenerated -- a recurring chore that
looks exactly like a bug from the phone.
Weaker than the exact list by construction: a prefix allows packages that do
not exist yet. Keep the prefixes narrow and vendor-specific for that reason.

## Night Curfew Whitelist

NIGHT CURFEW WHITELIST
These are the ONLY third-party apps that stay enabled during the curfew
window (see NIGHT_CURFEW_* above). Everything else in $WHITELIST — browsers,
social, messaging, email, stores, transit — is disabled.
Allow-list by design: when in doubt, leave it OUT.
EXCEPTION: $NIGHT_ALLOWED_PREFIXES is applied on top of this list. It carries
"eu.kanade.tachiyomi" — so manga IS available during the curfew, deliberately
(chosen 2026-08-14) — plus "com.kuhy" and "dev.kuhy" as of 2026-08-26, which
make every app kuhy writes available at night (see the section below). This
paragraph used to say manga was disabled at night; it was true until that
change. Do not "restore" it without also emptying $NIGHT_ALLOWED_PREFIXES, or
the comment and the behaviour disagree again.
Parsed exactly like $WHITELIST (one package per line, '#' comments ignored).
The sysprotect prefixes ($SYSTEM_NEVER_DISABLE) and the default-handler guard
(dialer/SMS/home/browser/IME) still apply on TOP of this list, so the active
keyboard and core system apps are protected even if omitted here.

**NIGHT_WHITELIST must be a subset of WHITELIST.** The curfew list is a
narrowing of the day list, never an addition to it, so a package added here
has to be in WHITELIST too. This is an enforced invariant, not a convention:
`focus_policy/model.py` raises `PolicyError: night_allowed_packages must be a
subset of allowed_packages`, so violating it fails policy generation rather
than shipping a phone that behaves oddly at 23:00. The same relationship holds
for $NIGHT_ALLOWED_PREFIXES against $ALLOWED_PREFIXES.

## System packages that must never be disabled

--- System / essential packages that must NEVER be disabled ---
These are matched as prefixes (startswith).
You generally don't need to edit this list.
pl.infakt.infakt is the one non-system entry. Allowlisting it is weaker:
that depends on it staying in BOTH the day and night lists, and dropping it
from either would silently make it hideable. It is device-paired to a bank
over SMS, so losing access to it strands the same re-authentication chain a
hidden Messages app would. isAllowed() checks this list first, before the
curfew split, so it holds under every condition.

## Whitelisted apps

WHITELISTED APPS
These apps will ALWAYS remain enabled, even in focus mode.
Package names verified against installed packages on 2026-02-22.

## Night curfew

NIGHT CURFEW (time-gated strict allow-list)
When focus mode is ON (i.e. you are at home) AND the local clock is inside
the curfew window, the daemon switches from the permissive $WHITELIST to the
strict $NIGHT_WHITELIST: every app not on that short list is disabled. This
is the "stop using the phone after 23:00 at home" layer. The companion
enforcer (curfew_enforcer.sh) adds grayscale + DND + an optional per-UID
network allow-list on top. Times are local 24h "HHMM"; the window wraps past
midnight when START > END (e.g. 2300 -> 0500).

## Why dev.kuhy.todo is in the night list

Capture-only notes app. Added 2026-08-14 after a curfew-window deploy
installed it and the enforcer removed the package ~80ms later: it was in
the day list but not here, so any build shipped after 23:00 was silently
uninstalled. This is a deliberate loosening of the answer-the-phone /
reach-a-bank / handle-an-emergency rule above -- writing an idea down at
night is the one thing this app does, and losing the deploy path for six
hours a day cost more than the distraction risk.

## Why com.kuhy.punchme is in the night list

Work-hours check-in/check-out tracker. Added 2026-08-25 for the same reason
as `dev.kuhy.todo` above: it is in the day list, so a build shipped inside
the curfew window would be installed and then silently removed by the
enforcer, losing the deploy path for six hours a day.

The night-usage case is weaker than todo's -- you are not meant to be
checking in at 02:00 -- but it is not zero: a late shift that runs past
23:00 still has to be checked out, and the alternative is an untracked day.
Distraction risk is minimal for an app whose entire surface is one button.

## Why com.kuhy.dufs_client is in the night list

Client for the self-hosted dufs file server. Added 2026-08-25 at explicit
request: allowed always, at home and inside the curfew window alike.

Unlike `dev.kuhy.todo` and `com.kuhy.punchme` above, this is not only about
keeping the deploy path open -- reaching your own files is treated as
infrastructure rather than as a distraction, in the same category as the
password manager (`com.kunzisoft.keepass.libre`), which is already allowed
around the clock. It is a file browser against a server you host, not a
content feed, so it has no endless surface to fall into at 02:00.

## Why org.thoughtcrime.securesms is in the night list

Signal is messaging, and the curfew already keeps messaging reachable: the
fossify phone, messages and contacts apps are all in the night list so you can
still be called or texted at 02:00. Signal carries the same traffic for the
people who use it, so excluding it made the curfew's own stated rule ("what is
needed to answer the phone") true only for people who happen to text by SMS.

**A correction, recorded rather than quietly fixed.** When Signal was first
added to the day list on 2026-08-29 the comment justified it like this: the
signal-bot in `~/src/signal-bot` runs as a *linked device* of this account, a
linked device can only be created by scanning a QR code in the phone app, so
hiding Signal would make the bot unre-linkable. It then concluded that the day
list was enough, because "the link survives the app being disabled".

That reasoning was wrong at both ends. The bot does not ride this account at
all -- `scripts/register_bot.sh` registers it a **separate number** of its own,
and `GET /v1/devices/<bot number>` returns exactly one device with `id: 1`.
Device 1 is the primary; a linked device is 2 or higher. Verified 2026-08-29.
So hiding Signal on this phone costs the bot nothing, and the entry is not
load-bearing for it in either list.

The real reasons Signal is whitelisted are narrower and worth stating plainly:
it is kuhy's messaging app, and adding the bot to a *new* group has to be done
from the phone app, because signal-cli cannot accept a group invitation
addressed to a phone number.

## Why every com.kuhy / dev.kuhy package is allowed by prefix

Added 2026-08-26. `com.kuhy` and `dev.kuhy` are in BOTH $ALLOWED_PREFIXES and
$NIGHT_ALLOWED_PREFIXES, so every app kuhy writes is available at home, day and
night, including apps that do not exist yet.

This replaces a recurring chore with a rule. Three of the sections above
(`dev.kuhy.todo`, `com.kuhy.punchme`, `com.kuhy.dufs_client`) exist because an
app sat in the day list but not the night list, and a build shipped inside the
curfew window was installed and then removed by the enforcer ~80ms later. That
is not three incidents with three causes; it is one cause met three times.
`com.kuhy.workout_app` was the fourth, fixed in this same change.
`com.kuhy.focusstatus` was a fifth in waiting — referenced by four scripts and
absent from both lists, so it would have been hidden the moment it was
installed.

The device settled the argument. When this change was verified during a real
curfew (2026-08-26, 23:01), three installed apps turned out to be in NO list at
all: `com.kuhy.macro_cam`, `dev.kuhy.kuhylog` and `dev.kuhy.octoforge`. The old
exact-match policy was hiding them every night and nobody had noticed. They are
allowed now purely by prefix, which is the whole point: the list had already
drifted behind reality, and enumerating harder was never going to catch up.

### Why this does not violate the narrow-prefix rule above

"Allowed Package Prefixes" says prefixes are weaker by construction because they
allow packages that do not yet exist, and to keep them narrow and
vendor-specific. `com.kuhy` IS vendor-specific, and the usual danger does not
apply here: there is no store on the device that can serve a `com.kuhy.*`
package. Play is hidden at home, Aurora was removed, and installs are PC-side
over `deploy.sh --sideload`. A package matching this prefix can only arrive by
kuhy building and sideloading it — precisely the event this change exists to
stop punishing. The prefix does not widen what can reach the device; it stops
the enforcer deleting what was deliberately put there.

Two prefixes rather than one because the apps use two vendor namespaces:
`com.kuhy.*` for everything current, plus the older `dev.kuhy.todo`.

### NO TRAILING DOT

Write `com.kuhy`, never `com.kuhy.`. Matching is on whole labels
(`FocusPolicy._matches_prefix`, mirrored in `FocusPolicy.kt`):

    package == prefix || package.startswith(prefix + ".")

A trailing dot therefore matches NOTHING — `com.kuhy.` fails even against
`com.kuhy.workout_app` — and it fails silently, while still reading as correct.
Whole-label matching is also why `com.kuhy` cannot leak to a lookalike vendor
such as `com.kuhyevil.spy`.

The explicit per-app entries in $WHITELIST and $NIGHT_WHITELIST are now
redundant to the prefix and are kept on purpose: they are a readable inventory
of what is actually installed, and they mean the lists do not depend solely on
the prefix being right.

`tests/test_policy_kuhy_apps.py` is the gate for all of the above, including the
trailing-dot trap. A comment is not a gate.

### One divergence, recorded rather than fixed

`daemon_apps.sh` `is_allowed()` matches the whitelists with `grep -qxF` (exact)
and applies prefixes only to `sysprotect.txt`, so that path ignores
$ALLOWED_PREFIXES entirely. It does not affect the Pixel 6a, which is unrooted
and enforced by `com.kuhy.focus_owner` as Device Owner reading the generated
`policy.json`; the shell daemon is the rooted-device legacy path and is not
running there. The divergence predates this change — `eu.kanade.tachiyomi` has
the same blind spot — so bringing the two to parity is a separate change.

## Why com.facebook.orca left the day list

Removed 2026-09-18. Messenger used to sit in `WHITELIST` next to the fossify
phone/messages/contacts entries, so it was visible at home and hidden only in
the curfew. It is now absent from both lists: hidden at home and in the
curfew, visible away from home like every other unlisted app.

It is deliberately **not** in `ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES`: the
"hide everywhere" tier was offered and declined. Chat with friends moved to
the PC, where `messenger.com` is allowed and the `facebook.com` feed is
blocked by managed browser policy (`~/src/hosts-blocker`,
`lib/hosts_browser_urlfilter.sh`), so the phone app only needs to exist for
the away case.

The Messenger *web* clients on the phone are covered by the soft RethinkDNS
layer instead -- see `config_rethink.sh` -- and only through the web hosts
(`www.`/`m.`/`web.`/`mbasic.facebook.com`, `messenger.com`), never a bare
`facebook.com` rule, because the app talks to `graph.`/`edge-mqtt.`/
`b-api.facebook.com` and would stop working when away.

## Why the food-delivery apps are hidden everywhere

Added 2026-09-18 to `ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES`, next to Uber:
`com.yourdelivery.pyszne` (Pyszne.pl), `com.glovo`, `com.wolt.android`,
`com.bolt.deliveryclient`. None is installed; listing them is what makes an
install-and-order relapse fail rather than succeed, in the AWAY branch too.
Every id was checked against `play.google.com/store/apps/details?id=` before
landing -- Pyszne.pl is **not** `com.pyszne.*`, and a mistyped id is a silent
no-op that looks identical to a working block.

The browser path to the same services is the soft RethinkDNS layer
(`config_rethink.sh`, pushed by `python3 -m rethink_rules`); the PC has had
the same domains in `hosts-blocker/custom_entries.hosts` for longer.

The Play Store rationale continues in `DOCS-policy-play-store.md`.
