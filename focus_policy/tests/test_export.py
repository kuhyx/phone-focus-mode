"""Tests for the JSON policy exporter.

The guarantee under test is the one that cannot be recovered from on the device
itself: the enforcing app must never be rendered into a policy that would hide
it. Everything else here is shape, not safety.
"""

from __future__ import annotations

import datetime as dt

from python_pkg.focus_policy.export import (
    ENFORCER_PACKAGE,
    policy_to_dict,
    policy_to_json,
)
from python_pkg.focus_policy.model import CurfewWindow, FocusPolicy, HomeLocation

_DEFAULT_CURFEW = CurfewWindow(start=dt.time(23, 0), end=dt.time(5, 0))


def _policy(
    *,
    # The launcher must be allowed or the model rejects the policy outright.
    allowed_packages: frozenset[str] = frozenset({"pl.mbank", "com.launcher"}),
    night_allowed_packages: frozenset[str] = frozenset({"pl.mbank", "com.launcher"}),
    curfew: CurfewWindow | None = _DEFAULT_CURFEW,
) -> FocusPolicy:
    """Build a policy with the enforcer deliberately absent from both lists."""
    return FocusPolicy(
        home=HomeLocation(
            latitude=52.2297,
            longitude=21.0122,
            radius_m=150.0,
            hysteresis_m=30.0,
        ),
        curfew=curfew,
        launcher_package="com.launcher",
        allowed_packages=allowed_packages,
        night_allowed_packages=night_allowed_packages,
        never_disable_prefixes=("com.android.",),
        workout_unblock_domains=frozenset({"youtube.com"}),
        browser_packages=frozenset({"org.mozilla.firefox"}),
    )


def test_enforcer_is_injected_into_both_allowlists() -> None:
    """The app must be allowed even when the source config omits it.

    Regression guard for the on-device finding of 2026-08-09: the enforcer was
    in neither allowlist, so the decision layer placed it in the hide set on
    every enforcing pass, leaving one in-app check as the sole thing preventing
    the app from hiding itself.
    """
    payload = policy_to_dict(_policy())

    assert ENFORCER_PACKAGE in payload["allowed_packages"]
    assert ENFORCER_PACKAGE in payload["night_allowed_packages"]


def test_enforcer_is_not_duplicated_when_already_present() -> None:
    """Injection is a set union, so an explicit entry stays single."""
    payload = policy_to_dict(
        _policy(
            allowed_packages=frozenset({"pl.mbank", "com.launcher", ENFORCER_PACKAGE}),
            night_allowed_packages=frozenset({"com.launcher", ENFORCER_PACKAGE}),
        ),
    )

    assert payload["allowed_packages"].count(ENFORCER_PACKAGE) == 1
    assert payload["night_allowed_packages"].count(ENFORCER_PACKAGE) == 1


def test_blockable_system_packages_names_the_distraction_apps() -> None:
    """The sweep is default-deny for system apps; this is the opt-in.

    YouTube and Chrome ship with FLAG_SYSTEM, so without this list the Device
    Owner sweep skips exactly the apps it exists to block. Play is included
    because leaving it reachable makes every other removal a one-tap undo.
    """
    blockable = policy_to_dict(_policy())["blockable_system_packages"]

    assert "com.google.android.youtube" in blockable
    assert "com.android.chrome" in blockable
    assert "com.android.vending" in blockable


def test_blockable_system_packages_never_contradicts_the_allowlist() -> None:
    """An allowed package must not also be listed as blockable.

    Otherwise the asset would state both at once and the outcome would depend
    on which check the runner happened to apply first.
    """
    payload = policy_to_dict(
        _policy(
            allowed_packages=frozenset(
                {"pl.mbank", "com.launcher", "com.android.chrome"},
            ),
        ),
    )

    assert "com.android.chrome" not in payload["blockable_system_packages"]
    assert "com.android.chrome" in payload["allowed_packages"]


def test_always_blocked_exempts_youtube_and_chrome_from_the_geofence() -> None:
    """The geofence must not become an off switch for these.

    Everything else is restored on the AWAY branch, which makes leaving the
    house a way to switch enforcement off -- the specific thing Device Owner
    was provisioned to remove. Play is deliberately absent: it stays geofenced
    so apps can still be installed away from home.
    """
    always = policy_to_dict(_policy())["always_blocked_packages"]

    assert "com.google.android.youtube" in always
    assert "com.google.android.apps.youtube.music" in always
    assert "com.android.chrome" in always
    assert "com.android.vending" not in always


def test_always_blocked_is_a_subset_of_blockable() -> None:
    """An always-blocked system app the sweep cannot see would silently no-op.

    The runner filters FLAG_SYSTEM packages out of ``installedPackages``
    unless they are opted in, so the decision layer would never receive them.
    """
    payload = policy_to_dict(_policy())

    assert set(payload["always_blocked_packages"]) <= set(
        payload["blockable_system_packages"],
    )


def test_always_blocked_never_contradicts_the_allowlist() -> None:
    """Allowing a package wins over always-blocking it.

    The asset must not state both at once; the subtraction keeps the two
    fields consistent no matter what config.sh says.
    """
    payload = policy_to_dict(
        _policy(
            allowed_packages=frozenset(
                {"pl.mbank", "com.launcher", "com.android.chrome"},
            ),
        ),
    )

    assert "com.android.chrome" not in payload["always_blocked_packages"]
    assert "com.android.chrome" in payload["allowed_packages"]


def test_lists_are_sorted_for_stable_diffs() -> None:
    """Sorted output keeps a committed asset's diff meaningful."""
    payload = policy_to_dict(_policy())

    for key in (
        "allowed_packages",
        "night_allowed_packages",
        "never_disable_prefixes",
        "workout_unblock_domains",
        "browser_packages",
    ):
        assert payload[key] == sorted(payload[key])


def test_curfew_is_rendered_as_wall_clock_strings() -> None:
    """Kotlin parses `HH:MM`, not an ISO time."""
    assert policy_to_dict(_policy())["curfew"] == {"start": "23:00", "end": "05:00"}


def test_absent_curfew_renders_as_null() -> None:
    """A policy with no curfew must not fabricate one."""
    assert policy_to_dict(_policy(curfew=None))["curfew"] is None


def test_redact_home_blanks_coordinates_but_keeps_geometry() -> None:
    """A committed asset discloses the radius, never the location."""
    payload = policy_to_json(_policy(), redact_home=True)

    assert '"latitude": null' in payload
    assert '"longitude": null' in payload
    assert '"radius_m": 150.0' in payload


def test_coordinates_survive_when_not_redacted() -> None:
    """The provisioning path still needs the real values."""
    assert '"latitude": 52.2297' in policy_to_json(_policy())
