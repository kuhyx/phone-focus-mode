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

from focus_policy.packages import (
    ALWAYS_BLOCKED_PACKAGES,
    ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES,
    ALWAYS_ON_VPN_PACKAGE,
    BLOCKABLE_SYSTEM_PACKAGES,
    ENFORCER_PACKAGE,
    PRIVATE_DNS_HOST,
    VPN_LOCKDOWN,
)

if TYPE_CHECKING:
    from focus_policy.model import FocusPolicy

SCHEMA_VERSION = 1

__all__ = [
    "ALWAYS_BLOCKED_PACKAGES",
    "ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES",
    "ALWAYS_ON_VPN_PACKAGE",
    "BLOCKABLE_SYSTEM_PACKAGES",
    "ENFORCER_PACKAGE",
    "PRIVATE_DNS_HOST",
    "SCHEMA_VERSION",
    "VPN_LOCKDOWN",
    "policy_to_dict",
    "policy_to_json",
]

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
        # Prefix-matched allowlists. Absent from an older asset, so both
        # parsers must read a missing key as the empty tuple -- which restores
        # exactly the previous exact-match-only behaviour.
        "allowed_prefixes": sorted(policy.allowed_prefixes),
        "night_allowed_prefixes": sorted(policy.night_allowed_prefixes),
        "workout_unblock_domains": sorted(policy.workout_unblock_domains),
        "browser_packages": sorted(policy.browser_packages),
        # Absent from an older asset, so the Kotlin loader must treat a
        # missing key as the empty set -- i.e. keep today's behaviour of
        # never touching a system app.
        #
        # Only the enforcer is subtracted. The allowlist is deliberately NOT,
        # because sweepable != hideable: being in this list makes a package
        # *eligible for a decision*, and `isAllowed` is what then protects it.
        # Removing an allowed system package from the sweep does not protect
        # it, it freezes it -- `sweepablePackages` drops any FLAG_SYSTEM
        # package absent from here, so it lands in neither `packagesToHide`
        # nor `packagesToShow` and keeps whatever state it was last left in.
        # Measured: com.android.vending is hidden today, so allowlisting it
        # while subtracting here would have left Play hidden permanently, with
        # no in-app way to notice. Same failure as the MATCH_UNINSTALLED_PACKAGES
        # note in EnforcementRunner, reached by a different route.
        "blockable_system_packages": sorted(
            BLOCKABLE_SYSTEM_PACKAGES - {ENFORCER_PACKAGE},
        ),
        # An allowed package must never also be declared always-blocked, or the
        # asset would state both at once and the outcome would depend on which
        # check the runner happened to apply first. The enforcer itself can
        # never appear here -- hiding it takes the escape hatch with it.
        #
        # Filtered through `is_allowed` rather than subtracting the exact
        # allowlist, because allowance is no longer exact-only: a prefix that
        # happened to cover an always-blocked package would otherwise satisfy
        # `is_allowed` while still being emitted as always-blocked.
        "always_blocked_packages": sorted(
            pkg
            for pkg in (ALWAYS_BLOCKED_PACKAGES | ALWAYS_BLOCKED_THIRD_PARTY_PACKAGES)
            - {ENFORCER_PACKAGE}
            if not policy.is_allowed(pkg)
        ),
        "vpn_lockdown": VPN_LOCKDOWN,
        "private_dns_host": PRIVATE_DNS_HOST,
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
