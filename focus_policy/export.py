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
