"""Cross-checks between the always-blocked set and the allowlist."""

from __future__ import annotations

import datetime as dt

from python_pkg.focus_policy.export import (
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
    never_disable_prefixes: tuple[str, ...] = ("com.android.",),
    allowed_prefixes: tuple[str, ...] = (),
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
        allowed_prefixes=allowed_prefixes,
        night_allowed_packages=night_allowed_packages,
        never_disable_prefixes=never_disable_prefixes,
        workout_unblock_domains=frozenset({"youtube.com"}),
        browser_packages=frozenset({"org.mozilla.firefox"}),
    )


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


def test_a_prefix_allowance_also_wins_over_always_blocking() -> None:
    """Allowance is no longer exact-only, so the check must not be either.

    Subtracting just ``allowed_packages`` left a package allowed by prefix
    still emitted as always-blocked, so the asset stated both at once and the
    runner's behaviour depended on which check it applied first.
    """
    payload = policy_to_dict(
        _policy(
            allowed_packages=frozenset({"pl.mbank", "com.launcher"}),
            allowed_prefixes=("com.android.chrome",),
        ),
    )

    assert "com.android.chrome" not in payload["always_blocked_packages"]


def test_the_real_distraction_apps_stay_always_blocked() -> None:
    """The filter must not quietly un-block what the app exists to block."""
    payload = policy_to_dict(_policy())

    assert "com.google.android.youtube" in payload["always_blocked_packages"]
    assert "com.android.chrome" in payload["always_blocked_packages"]


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
