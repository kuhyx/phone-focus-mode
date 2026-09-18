# Policy lists: the Play Store decision

Split out of `DOCS-policy-lists.md` on 2026-09-18 for the 250-line cap. Same
content; anchors below are unchanged, only the file name moved.

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
