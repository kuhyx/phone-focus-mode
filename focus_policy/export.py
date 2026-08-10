"""Render a :class:`FocusPolicy` into a backend-neutral JSON document.

The Device Owner app is written in Kotlin and cannot read ``config.sh`` or
import this package. It reads this JSON instead, so both enforcement backends
stay driven by one policy definition.

Sorted keys and sorted lists keep the output stable, so committing a rendered
policy produces a meaningful diff when the policy actually changes rather than
noise from set iteration order.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from python_pkg.focus_policy.model import FocusPolicy

SCHEMA_VERSION = 1

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
# every other removal a one-tap undo.
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
# com.android.vending is deliberately NOT here: Play stays geofenced so apps
# can still be installed and updated away from home, and a hidden package
# cannot be reinstalled from Play anyway.
ALWAYS_BLOCKED_PACKAGES = frozenset(
    {
        "com.android.chrome",
        "com.google.android.apps.youtube.music",
        "com.google.android.youtube",
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

# Every always-blocked package here is preinstalled, so it only ever reaches
# the sweep by also being opted in above. Listing one without the other would
# not error -- it would silently never be hidden, because the runner filters it
# out of installedPackages before the decision layer sees it.
_UNSWEEPABLE = ALWAYS_BLOCKED_PACKAGES - BLOCKABLE_SYSTEM_PACKAGES
if _UNSWEEPABLE:  # pragma: no cover - guards a constant, not a code path
    msg = (
        "always-blocked system packages must also be blockable, or the sweep "
        f"never sees them: {sorted(_UNSWEEPABLE)}"
    )
    raise ValueError(msg)


def policy_to_dict(policy: FocusPolicy) -> dict[str, Any]:
    """Return a JSON-serialisable representation of ``policy``."""
    curfew: dict[str, str] | None = None
    if policy.curfew is not None:
        curfew = {
            "start": policy.curfew.start.strftime("%H:%M"),
            "end": policy.curfew.end.strftime("%H:%M"),
        }

    return {
        "schema_version": SCHEMA_VERSION,
        "home": {
            "latitude": policy.home.latitude,
            "longitude": policy.home.longitude,
            "radius_m": policy.home.radius_m,
            "hysteresis_m": policy.home.hysteresis_m,
        },
        "curfew": curfew,
        "launcher_package": policy.launcher_package,
        "allowed_packages": sorted({*policy.allowed_packages, ENFORCER_PACKAGE}),
        "night_allowed_packages": sorted(
            {*policy.night_allowed_packages, ENFORCER_PACKAGE},
        ),
        "never_disable_prefixes": sorted(policy.never_disable_prefixes),
        "workout_unblock_domains": sorted(policy.workout_unblock_domains),
        "browser_packages": sorted(policy.browser_packages),
        # Absent from an older asset, so the Kotlin loader must treat a
        # missing key as the empty set -- i.e. keep today's behaviour of
        # never touching a system app.
        "blockable_system_packages": sorted(
            BLOCKABLE_SYSTEM_PACKAGES - {*policy.allowed_packages, ENFORCER_PACKAGE},
        ),
        # Same subtraction, for the same reason: an allowed package must never
        # also be declared always-blocked, or the asset would state both at
        # once. The enforcer itself can never appear here -- hiding it takes
        # the escape hatch with it.
        "always_blocked_packages": sorted(
            ALWAYS_BLOCKED_PACKAGES - {*policy.allowed_packages, ENFORCER_PACKAGE},
        ),
        "vpn_lockdown": VPN_LOCKDOWN,
        # Emitted only when the provider is protected from the sweep. Pinning a
        # package the enforcer can hide is the worst case: DISALLOW_CONFIG_VPN
        # points at a hidden app and the device loses connectivity rather than
        # just the filter.
        "always_on_vpn_package": (
            ALWAYS_ON_VPN_PACKAGE if policy.is_protected(ALWAYS_ON_VPN_PACKAGE) else ""
        ),
    }


def policy_to_json(policy: FocusPolicy, *, redact_home: bool = False) -> str:
    """Return ``policy`` as pretty-printed JSON.

    ``redact_home`` blanks the coordinates so a rendered policy can be attached
    to a bug report or committed as a fixture without disclosing where the user
    lives. The radius and hysteresis are kept, since they carry no location.
    """
    payload = policy_to_dict(policy)
    if redact_home:
        payload["home"] = dict(payload["home"], latitude=None, longitude=None)
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False)
