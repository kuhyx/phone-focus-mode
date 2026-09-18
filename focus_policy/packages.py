"""The package-level decisions the exporter bakes into every policy.

Split out of ``export.py`` on 2026-09-18 to keep both files under the
250-line cap. Nothing here is derived from ``config.sh``: these are the sets
that are the same for every policy -- the enforcer's own package, the system
apps it is allowed to sweep, the apps hidden everywhere, and the VPN pin.
Every name is re-exported by ``focus_policy.export`` so existing imports and
the tests keep working.
"""

from __future__ import annotations

# The enforcing app itself, which must never appear in the hide set. Hiding it
# removes both the escape hatch and the control that triggers the next pass,
# leaving no way back short of a factory reset. The Kotlin runner does check
# this at the point of use, but that check is the *only* protection unless the
# package is also allowed here -- so it is injected into the exported allowlists
# rather than left to a hand-edit of the rendered asset.
ENFORCER_PACKAGE = "com.kuhy.focus_owner"

# System apps the sweep is allowed to hide, named one by one.
#
# The Kotlin runner skips every package with FLAG_SYSTEM, which means the
# Device Owner path cannot touch the apps most worth blocking: YouTube ships
# at /product/app/YouTube as a system app, and so does Chrome. Simply dropping
# that filter is not the fix -- measured on the Pixel 6a, it would expose 320
# system packages of which 243 match no allowlist entry and no
# never_disable_prefix, including com.android.cellbroadcastreceiver (emergency
# alerts), com.android.credentialmanager and com.android.devicelockcontroller.
# Hiding those under Device Owner risks an unrecoverable device.
#
# So the sweep stays default-deny for system apps and this is the opt-in.
# com.android.vending is included deliberately: leaving Play reachable makes
# every other removal a one-tap undo. Being sweepable is what makes it eligible
# for a decision at all; dropping it from the allowlists is what makes that
# decision "hide" at home, while the AWAY branch still shows it.
BLOCKABLE_SYSTEM_PACKAGES = frozenset(
    {
        "com.android.chrome",
        "com.android.vending",
        "com.google.android.apps.youtube.music",
        "com.google.android.videos",
        "com.google.android.youtube",
    },
)

# Packages hidden everywhere, regardless of location, curfew or workout.
#
# The geofence exists so the phone becomes usable again away from home, but
# that makes leaving the house an off switch -- which is the specific thing
# Device Owner was provisioned to remove. These are exempt from it: the
# decision layer never puts them in packagesToShow, so the AWAY branch cannot
# restore them.
#
# Chrome is here because it is a second route to the same content, not because
# browsing is banned -- Firefox stays available and carries the uBlock filters.
# com.android.vending is deliberately NOT here, but it is also absent from the
# day and night allowlists -- so Play is hidden AT HOME (day and night) and
# shown only on the AWAY branch. That split is a measured constraint, not a
# preference.
#
# Measured on device 2026-08-24: infakt is wrapped in Google PairIP license
# verification. At startup it binds com.android.vending.licensing.ILicensingService,
# which is implemented by com.google.android.finsky.services.LicensingService
# INSIDE the vending package. Hide vending and the bind fails
# ("Unable to start service ... not found"), LicenseActivity takes over, and
# infakt refuses to open with "Something went wrong / Check that Google Play is
# enabled". It is IPC into the vending package, so no hostname or DNS change can
# substitute -- Play must be present and unhidden for infakt to run at all.
#
# Blocking Play at home is what matters: that is where the browser-install
# bypass would be used. Away from home the phone is deliberately usable, and
# that is also the window in which infakt can be opened.
ALWAYS_BLOCKED_PACKAGES = frozenset(
    {
        "com.android.chrome",
        "com.google.android.apps.youtube.music",
        "com.google.android.youtube",
    },
)

# Third-party packages hidden everywhere, same geofence exemption as above.
#
# Separate from ALWAYS_BLOCKED_PACKAGES because the sweepability opt-in below
# exists only for FLAG_SYSTEM apps, which the Kotlin runner skips. These are
# ordinary installed apps: the runner already sees them, so requiring them in
# BLOCKABLE_SYSTEM_PACKAGES would be wrong -- that set means "a system app we
# have decided is safe to hide", which these are not.
#
# Added 2026-08-31: an Uber account deletion is in its 30-day grace window and
# a single sign-in restores the account. The app is the likeliest relapse
# route, so it stays hidden away from home too, where the geofence would
# otherwise show it. Neither package is installed today; listing them is what
# makes a reinstall-and-sign-in fail rather than succeed.
#
# Added 2026-09-18: the other food-delivery platforms, for the same reason as
# Uber Eats -- the app is the relapse route, and none is installed today. The
# ids were each checked against play.google.com/store/apps/details?id=<pkg>
# before landing here: a mistyped id is a silent no-op that looks identical
# to a working block. Pyszne.pl is com.yourdelivery.pyszne, not com.pyszne.*.
ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES = frozenset(
    {
        "com.bolt.deliveryclient",
        "com.glovo",
        "com.ubercab",
        "com.ubercab.eats",
        "com.wolt.android",
        "com.yourdelivery.pyszne",
    },
)

# The always-on VPN provider, pinned by the device owner on every pass.
#
# This is the network-level block: package hiding stops the YouTube app, but
# only a VPN reaches youtube.com in Firefox, in a webview, or in any client
# that has not been thought of. Named here rather than hardcoded in Kotlin so
# the asset stays the single description of the policy.
ALWAYS_ON_VPN_PACKAGE = "com.celzero.bravedns"

# Whether the pinned VPN runs in lockdown mode: no traffic at all leaves the
# device unless it goes through the tunnel.
#
# This is what closes "turn the VPN off and browse freely" -- without it the
# filter is advisory. The cost is real and is accepted deliberately: if the
# VPN app breaks, the phone has no connectivity until device ownership is
# released. That is survivable only because the release path lives in the
# enforcer app itself and needs no network.
VPN_LOCKDOWN = True

# Private DNS host pinned by the device owner, or "" to leave it alone.
#
# This is where the domain rules actually live. RethinkDNS's blocklists were
# measured to be switchable off from inside that app in a few taps, and no
# device owner API can prevent it -- so the block moves to a resolver on the
# PC that the phone has no way to edit. The VPN stays pinned alongside it,
# because Private DNS does not stop a browser's built-in DoH.
# Empty until the resolver is reachable from the phone. Measured 2026-08-11:
# stunnel's log recorded zero connections from the handset during two pin
# attempts, so setGlobalPrivateDnsModeSpecifiedHost returned
# PRIVATE_DNS_SET_ERROR_HOST_NOT_SERVING -- the router does not forward 853.
# Android's `nc -z` on the device reported the port OPEN three times and was
# simply wrong; toybox nc does not implement -z, so the server-side log is the
# only trustworthy evidence here.
#
# There is a second, deeper reason not to enable this yet: while a VPN with
# lockdown holds the tunnel, app DNS goes to the VPN's own resolver rather
# than the system Private DNS path, so a successful pin would carry no block.
PRIVATE_DNS_HOST = ""

# Every always-blocked package in ALWAYS_BLOCKED_PACKAGES is preinstalled, so it
# only ever reaches the sweep by also being opted in above. Listing one without
# the other would not error -- it would silently never be hidden, because the
# runner filters it out of installedPackages before the decision layer sees it.
#
# ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES is deliberately NOT checked here: those
# are not FLAG_SYSTEM, so the runner never filters them out and the opt-in does
# not apply. Adding them to BLOCKABLE_SYSTEM_PACKAGES to satisfy this guard
# would be a lie about what that set means.
_UNSWEEPABLE = ALWAYS_BLOCKED_PACKAGES - BLOCKABLE_SYSTEM_PACKAGES
if _UNSWEEPABLE:  # pragma: no cover - guards a constant, not a code path
    msg = (
        "always-blocked system packages must also be blockable, or the sweep "
        f"never sees them: {sorted(_UNSWEEPABLE)}"
    )
    raise ValueError(msg)
