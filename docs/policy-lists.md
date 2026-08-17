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

## Why the Play Store is in the day list

--- App store (day only; deliberately absent from the night list) ---
NB: never write a dollar-sign variable reference inside this list. WHITELIST
is a double-quoted string, so even a comment line expands, and deploy.sh
runs under set -u, where an undefined name aborts the whole deploy. A
reference to the night list sat here and did exactly that (it is defined
below this point, so it was still unset), blocking every focus-mode deploy.
Same rule for double quotes: one in a comment ends the string early.
infakt cannot be installed or updated without Play, and it is device-paired
to a bank, so losing the ability to update it strands a re-authentication
chain. This does NOT reopen YouTube: the sweep is default-deny for
third-party packages, so anything installed from Play is hidden on the next
at-home pass, and the always-blocked set (YouTube, Chrome) is never restored
by the AWAY branch either. Reinstalling YouTube from Play is UNTESTED as a
bypass:
the sweep would re-hide it within one pass regardless, but treat the claim
that Play cannot resurrect a blocked app as unverified until someone tries.
NOTE: never use a double-quote character anywhere inside these export
blocks, not even in a comment. The policy loader matches a quoted value up
to the next quote, so one stray quote terminates the string early and
silently truncates the allowlist -- which drops apps with no error at all.
