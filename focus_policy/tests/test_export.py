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


def test_an_allowed_system_package_stays_sweepable() -> None:
    """An allowed system package must stay in the sweep, or it freezes.

    Sweepable is not the same as hideable. This list decides which FLAG_SYSTEM
    packages are *eligible for a decision*; ``is_allowed`` is what then
    protects them. ``sweepablePackages`` in the Kotlin runner drops any system
    package absent from here, so an allowed-but-unsweepable package appears in
    neither ``packagesToHide`` nor ``packagesToShow`` and keeps whatever state
    it was last left in.

    Measured on device: Play was hidden, so subtracting the allowlist here
    would have stranded it hidden permanently the moment it was allowlisted.
    """
    payload = policy_to_dict(
        _policy(
            allowed_packages=frozenset(
                {"pl.mbank", "com.launcher", "com.android.vending"},
            ),
        ),
    )

    assert "com.android.vending" in payload["blockable_system_packages"]
    assert "com.android.vending" in payload["allowed_packages"]


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


def test_always_on_vpn_requires_a_sweep_protected_provider() -> None:
    """Pinning a package the enforcer can hide is the worst failure mode.

    DISALLOW_CONFIG_VPN pointing at a hidden app costs general connectivity,
    not just the filter, so the field is emitted only when the provider is
    protected.
    """
    unprotected = policy_to_dict(_policy())["always_on_vpn_package"]
    protected = policy_to_dict(
        _policy(never_disable_prefixes=("com.celzero.bravedns",)),
    )["always_on_vpn_package"]

    assert unprotected == ""
    assert protected == "com.celzero.bravedns"


def test_private_dns_host_is_exported_for_pinning() -> None:
    """The domain rules live on this resolver, not in the VPN app.

    Measured on 2026-08-11: RethinkDNS's blocklists can be switched off from
    inside that app in a few taps, and no device owner API prevents it. A
    pinned Private DNS host moves the rules somewhere the phone cannot edit.
    """
    payload = policy_to_dict(_policy())

    # Empty until the resolver is reachable from the phone: pinning an
    # unreachable host means no DNS at all, and Android refuses it anyway
    # (PRIVATE_DNS_SET_ERROR_HOST_NOT_SERVING).
    assert payload["private_dns_host"] == ""
    assert payload["vpn_lockdown"] is True
