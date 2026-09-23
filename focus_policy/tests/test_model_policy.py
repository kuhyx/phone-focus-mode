"""Tests for the FocusPolicy aggregate."""

from __future__ import annotations

from datetime import time

import pytest

from focus_policy.model import (
    CurfewWindow,
    FocusPolicy,
    HomeLocation,
    PolicyError,
)

HOME = HomeLocation(latitude=52.2297, longitude=21.0122)
METRES_PER_DEGREE_LAT = 111_320.0


def _policy(
    *,
    allowed_packages: frozenset[str] | None = None,
    night_allowed_packages: frozenset[str] | None = None,
    curfew: CurfewWindow | None = None,
    launcher_package: str | None = None,
    allowed_prefixes: tuple[str, ...] = (),
    night_allowed_prefixes: tuple[str, ...] = (),
    night_blocked_packages: frozenset[str] = frozenset(),
) -> FocusPolicy:
    """Build a small policy, overriding individual fields per test."""
    return FocusPolicy(
        home=HOME,
        allowed_packages=(
            frozenset({"com.good", "pl.mbank", "com.launcher"})
            if allowed_packages is None
            else allowed_packages
        ),
        night_allowed_packages=(
            frozenset({"pl.mbank"})
            if night_allowed_packages is None
            else night_allowed_packages
        ),
        never_disable_prefixes=("com.android.providers", "com.android.settings"),
        curfew=curfew,
        launcher_package=launcher_package,
        allowed_prefixes=allowed_prefixes,
        night_allowed_prefixes=night_allowed_prefixes,
        night_blocked_packages=night_blocked_packages,
    )


class TestFocusPolicy:
    """Allow/deny decisions and the invariants that keep the phone usable."""

    def test_rejects_launcher_outside_allowlist(self) -> None:
        """A policy that blocks its own launcher would leave no home screen."""
        with pytest.raises(PolicyError, match="no home screen"):
            _policy(launcher_package="com.missing")

    def test_accepts_launcher_inside_allowlist(self) -> None:
        """The guard permits a launcher that is actually allowed."""
        assert _policy(launcher_package="com.launcher").launcher_package

    def test_rejects_night_packages_absent_from_day_list(self) -> None:
        """A night allowance for a day-blocked package is contradictory."""
        with pytest.raises(PolicyError, match="subset"):
            _policy(night_allowed_packages=frozenset({"com.unknown"}))

    @pytest.mark.parametrize(
        ("package", "expected"),
        [
            ("com.android.settings", True),
            ("com.android.providers", True),
            ("com.android.providers.telephony", True),
            ("com.android.providersomething", False),
            ("com.good", False),
        ],
    )
    def test_protection_matches_whole_labels_only(
        self,
        package: str,
        *,
        expected: bool,
    ) -> None:
        """Prefix protection covers subpackages but not lookalike names.

        ``com.android.providers.telephony`` must be protected; the unrelated
        ``com.android.providersomething`` must not be swept in by a bare
        string prefix test.
        """
        assert _policy().is_protected(package) is expected

    def test_protected_packages_are_allowed_even_during_curfew(self) -> None:
        """Core system packages survive the strictest state."""
        policy = _policy()
        assert policy.is_allowed("com.android.settings", during_curfew=True)

    def test_curfew_narrows_the_allowlist(self) -> None:
        """Day-allowed apps can still be blocked at night."""
        policy = _policy()
        assert policy.is_allowed("com.good")
        assert not policy.is_allowed("com.good", during_curfew=True)
        assert policy.is_allowed("pl.mbank", during_curfew=True)

    def test_unknown_package_is_blocked(self) -> None:
        """Anything not explicitly allowed is denied."""
        assert not _policy().is_allowed("com.evil")

    def test_allowed_prefix_covers_a_family_of_packages(self) -> None:
        """Tachiyomi ships every source as its own apk.

        An exact list goes stale the moment a new extension is installed, which
        looks exactly like a bug from the phone.
        """
        policy = _policy(allowed_prefixes=("eu.kanade.tachiyomi",))
        assert policy.is_allowed("eu.kanade.tachiyomi")
        assert policy.is_allowed("eu.kanade.tachiyomi.sy")
        assert policy.is_allowed("eu.kanade.tachiyomi.extension.all.mangadex")

    def test_allowed_prefix_matches_whole_labels_only(self) -> None:
        """A bare string prefix would allow an unrelated package."""
        policy = _policy(allowed_prefixes=("eu.kanade.tachiyomi",))
        assert not policy.is_allowed("eu.kanade.tachiyomisomething")

    def test_a_day_only_prefix_is_blocked_during_curfew(self) -> None:
        """The night list narrows the prefixes too, not just the packages."""
        policy = _policy(allowed_prefixes=("eu.kanade.tachiyomi",))
        assert policy.is_allowed("eu.kanade.tachiyomi.sy")
        assert not policy.is_allowed("eu.kanade.tachiyomi.sy", during_curfew=True)

    def test_a_night_prefix_survives_the_curfew(self) -> None:
        """Manga is deliberately available at night (chosen 2026-08-14)."""
        policy = _policy(
            allowed_prefixes=("eu.kanade.tachiyomi",),
            night_allowed_prefixes=("eu.kanade.tachiyomi",),
        )
        assert policy.is_allowed("eu.kanade.tachiyomi.sy", during_curfew=True)
        assert policy.is_allowed(
            "eu.kanade.tachiyomi.extension.all.mangadex",
            during_curfew=True,
        )

    def test_night_prefixes_must_be_a_subset_of_day_prefixes(self) -> None:
        """The curfew tightens the day policy; it must never widen it."""
        with pytest.raises(PolicyError, match="night_allowed_prefixes"):
            _policy(night_allowed_prefixes=("eu.kanade.tachiyomi",))

    def test_is_curfew_active_without_window_is_false(self) -> None:
        """A policy with no curfew is never in curfew."""
        assert not _policy().is_curfew_active(time(23, 30))

    def test_is_curfew_active_with_window(self) -> None:
        """A configured window drives the curfew state."""
        policy = _policy(curfew=CurfewWindow(start=time(23, 0), end=time(5, 0)))
        assert policy.is_curfew_active(time(23, 30))
        assert not policy.is_curfew_active(time(12, 0))

    def test_packages_to_block_ignores_uninstalled(self) -> None:
        """Only packages present on the device can be blocked."""
        policy = _policy()
        installed = frozenset({"com.good", "com.evil", "com.android.settings"})
        assert policy.packages_to_block(installed) == frozenset({"com.evil"})

    def test_packages_to_block_during_curfew(self) -> None:
        """The curfew list is applied when the curfew flag is set."""
        policy = _policy()
        installed = frozenset({"com.good", "pl.mbank"})
        assert policy.packages_to_block(installed, during_curfew=True) == frozenset(
            {"com.good"},
        )

    def test_night_blocked_package_wins_over_a_matching_night_prefix(self) -> None:
        """A single package can be denied at night even though a whole-vendor
        prefix would otherwise cover it -- the com.kuhy.dufs_client case."""
        policy = _policy(
            allowed_packages=frozenset({"com.good", "pl.mbank", "com.launcher"}),
            allowed_prefixes=("com.vendor",),
            night_allowed_prefixes=("com.vendor",),
            night_blocked_packages=frozenset({"com.vendor.blocked"}),
        )
        # Allowed by day list too so the subset invariant is satisfied.
        assert policy.is_allowed("com.vendor.blocked")
        assert policy.is_allowed("com.vendor.other", during_curfew=True)
        assert not policy.is_allowed("com.vendor.blocked", during_curfew=True)

    def test_night_blocked_wins_even_via_the_exact_day_list(self) -> None:
        """Day allowance alone is not enough at night once night-blocked."""
        policy = _policy(night_blocked_packages=frozenset({"com.good"}))
        assert policy.is_allowed("com.good")
        assert not policy.is_allowed("com.good", during_curfew=True)

    def test_protected_packages_ignore_night_blocked(self) -> None:
        """A protected system package cannot be locked out via this tier."""
        policy = _policy()
        assert policy.is_allowed("com.android.settings", during_curfew=True)

    def test_night_blocked_must_be_a_subset_of_day_allowed(self) -> None:
        """Blocking a package the day policy never allowed is contradictory."""
        with pytest.raises(PolicyError, match="night_blocked_packages"):
            _policy(night_blocked_packages=frozenset({"com.unknown"}))

    def test_night_blocked_must_not_contradict_night_allowed(self) -> None:
        """A package cannot be both night-allowed and night-blocked."""
        with pytest.raises(PolicyError, match="night_blocked_packages"):
            _policy(
                night_allowed_packages=frozenset({"pl.mbank", "com.good"}),
                allowed_packages=frozenset({"com.good", "pl.mbank", "com.launcher"}),
                night_blocked_packages=frozenset({"com.good"}),
            )

    def test_night_blocked_must_not_include_the_launcher(self) -> None:
        """Night-blocking the launcher would leave no home screen at night."""
        with pytest.raises(PolicyError, match="no home screen"):
            _policy(
                launcher_package="com.launcher",
                night_blocked_packages=frozenset({"com.launcher"}),
            )

    def test_night_blocked_must_not_include_a_protected_package(self) -> None:
        """never_disable_prefixes already guarantees a protected package;
        naming it here too would be a self-contradiction."""
        with pytest.raises(PolicyError, match="night_blocked_packages"):
            _policy(
                allowed_packages=frozenset(
                    {"com.good", "pl.mbank", "com.launcher", "com.android.settings"},
                ),
                night_blocked_packages=frozenset({"com.android.settings"}),
            )
