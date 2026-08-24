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
EXCEPTION: $NIGHT_ALLOWED_PREFIXES is applied on top of this list, and it
currently carries "eu.kanade.tachiyomi" — so manga IS available during the
curfew, deliberately (chosen 2026-08-14). This paragraph used to say manga
was disabled at night; it was true until that change. Do not "restore" it
without also emptying $NIGHT_ALLOWED_PREFIXES, or the comment and the
behaviour disagree again.
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

## Why the Play Store is blocked

Changed 2026-08-24. Play used to sit in the day list, geofenced, with the
argument reproduced below. It is now in `ALWAYS_BLOCKED_PACKAGES`: hidden at
home and away, day and night, and blocked at the network layer as well.

The old argument was that a hidden package cannot be reinstalled from Play,
so leaving Play reachable could not undo anything. That only covers
*re-showing something already blocked*. It says nothing about **installing a
package the policy has never seen** -- and Play can fetch any browser in the
store. The app sweep is default-deny by package name, so a freshly installed
browser is hidden on the next pass, but "the next pass" is a window, and for
the length of that window the browser is a complete bypass of both the sweep
and the hosts blocklist. That install power is worth more to a bypass than
Play is to the phone.

Aurora Store was removed at the same time and for the same reason. It was
installed precisely to survive a Play block, which made it a Play client with
exactly the same install power -- the hole reproduced one layer down, wearing
the label of a mitigation.

### What this costs, and what it does not

It does **not** endanger infakt. `pl.infakt.infakt` is in
`SYSTEM_NEVER_DISABLE`, which `isAllowed()` consults before the curfew split,
so infakt survives every enforcement branch regardless of what happens to
Play. What is lost is only the ability to *update* it from the device, which
is what the section below replaces.

Blocking Play also does not touch push. `com.google.android.gms` is a
separate package, is itself in `SYSTEM_NEVER_DISABLE`, and is deliberately
left alone: it carries the Firebase push that infakt's browser-login approval
tap arrives on. Only `com.android.vending` is blocked, and the supplemental
hosts blocklist names APK-delivery hosts only, never the GMS push channel.

## Installing and updating apps without a store

There is no app store on the device. Installs and updates are PC-side:

```bash
./deploy.sh <phone-ip> --sideload /path/to/app.apk
```

That runs `adb install -r` -- never uninstall-then-install, which would drop
app data and, for infakt, the bank device pairing this procedure exists to
preserve.

For infakt specifically: fetch the current APK on the PC, sideload it, and
confirm on the phone that the app opens and a login-approval push still
arrives. See `DOCS-youtube-block-unrooted.md` on infakt before any factory
reset for what is and is not recoverable if the pairing is lost -- login
needs the password alone (2FA is SMS-only, so no TOTP seed exists), but the
banking pairing and the local app PIN do not survive and are re-paired over
SMS.

### The original argument, kept for the record

The text below is what the day-list entry said before 2026-08-24. It is
retained because it names a failure mode that is still real -- the
double-quote and dollar-sign rules for the export blocks are unchanged:

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
> chain. This does NOT reopen YouTube: the sweep is default-deny for
> third-party packages, so anything installed from Play is hidden on the next
> at-home pass, and the always-blocked set (YouTube, Chrome) is never
> restored by the AWAY branch either.
