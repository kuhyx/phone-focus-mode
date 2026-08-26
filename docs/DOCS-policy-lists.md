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

## Why the Play Store is blocked at home only

Changed 2026-08-24. Play used to sit in the day list, geofenced *and*
allowed. It is now geofenced and **not** allowed: absent from both
`WHITELIST` and `NIGHT_WHITELIST`, so the AT_HOME and CURFEW branches hide
it, while the AWAY branch still shows it.

Blocking it at home is the point. The old argument for allowing it was that a
hidden package cannot be reinstalled from Play, so leaving Play reachable
could not undo anything. That only covers *re-showing something already
blocked*. It says nothing about **installing a package the policy has never
seen** -- and Play can fetch any browser in the store. The app sweep is
default-deny by package name, so a freshly installed browser is hidden on the
next pass, but for the length of that window it is a complete bypass. Home is
where that bypass would be used, so home is where Play is hidden.

Aurora Store was removed at the same time and for the same reason. It was
installed precisely to survive a Play block, which made it a Play client with
exactly the same install power -- the hole reproduced one layer down, wearing
the label of a mitigation.

### Why it is not blocked away from home, and cannot be

infakt forces this, and it was measured on the device rather than assumed.

infakt is wrapped in Google **PairIP license verification**. On startup it
binds `com.android.vending.licensing.ILicensingService`, which is implemented
by `com.google.android.finsky.services.LicensingService` **inside the
`com.android.vending` package**. Hide Play and the bind fails:

```
W ActivityManager: Unable to start service Intent {
    act=com.android.vending.licensing.ILicensingService pkg=com.android.vending
  } U=0: not found
E LicenseClient: Error while checking license:
    com.pairip.licensecheck.LicenseCheckException: Could not bind with the
    licensing service
```

`LicenseActivity` then takes over and infakt refuses to open:

> Something went wrong. Check that Google Play is enabled on your device and
> that you're using an up-to-date version before opening the app.

This is IPC into the vending package, not a network call, so **no hostname,
DNS or VPN change can substitute for it** -- Play must be present and
unhidden for infakt to run at all. Hiding Play everywhere would not merely
strand infakt's updates, as the pre-2026-08-24 note assumed; it stops the app
from starting.

So the AWAY branch is the window in which infakt can be used. That is a real
cost -- Play works away from home, and so does its install power -- accepted
deliberately because losing infakt outright is worse.

### Why the hosts file blocks nothing here

`hosts_supplemental.txt` deliberately contains no Play hostname. A hosts file
is one static file, identical at home and away, so it cannot express a
geofence: any Play entry would apply on the AWAY branch too, and
`android.clients.google.com` in particular is the licensing/checkin endpoint,
so blocking it would break infakt exactly as hiding the package does. The app
layer is the correct layer, because hiding a package *is* geofence-aware.

`tests/test_hosts_supplemental.py` enforces this; the do-not-add list in that
file is a gate, not a comment.

## Installing and updating apps without a store

There is no app store client on the device (no Aurora), and Play is hidden at
home. Installs and updates are PC-side:

```bash
./deploy.sh <phone-ip> --sideload /path/to/app.apk
```

That runs `adb install -r` -- never uninstall-then-install, which would drop
app data and, for infakt, the bank device pairing.

See `DOCS-youtube-block-unrooted.md` on infakt before any factory reset for
what is and is not recoverable if that pairing is lost: login needs the
password alone (2FA is SMS-only, so no TOTP seed exists), but the banking
pairing and the local app PIN do not survive and are re-paired over SMS.

### The original argument, kept for the record

The text below is what the day-list entry said before 2026-08-24. Its claim
that losing Play only strands infakt's *updates* is now known to be wrong --
it stops infakt starting. The dollar-sign and double-quote rules it states
are still live:

> NB: never write a dollar-sign variable reference inside this list.
> WHITELIST is a double-quoted string, so even a comment line expands, and
> deploy.sh runs under set -u, where an undefined name aborts the whole
> deploy. A reference to the night list sat here and did exactly that (it is
> defined below this point, so it was still unset), blocking every
> focus-mode deploy. Same rule for double quotes: one in a comment ends the
> string early.
>
> infakt cannot be installed or updated without Play, and it is device-paired
> to a bank, so losing the ability to update it strands a re-authentication
> chain.
