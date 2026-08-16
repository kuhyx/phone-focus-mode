"""Tests for the policy model: geometry, curfew windows, and allow decisions."""

from __future__ import annotations

from datetime import time

import pytest

from python_pkg.focus_policy.model import (
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
    )


class TestHomeLocation:
    """Coordinate validation and distance maths."""

    @pytest.mark.parametrize(
        ("kwargs", "expected"),
        [
            ({"latitude": 91.0, "longitude": 0.0}, "latitude"),
            ({"latitude": -91.0, "longitude": 0.0}, "latitude"),
            ({"latitude": 0.0, "longitude": 181.0}, "longitude"),
            ({"latitude": 0.0, "longitude": -181.0}, "longitude"),
            ({"latitude": 0.0, "longitude": 0.0, "radius_m": 0.0}, "radius_m"),
            ({"latitude": 0.0, "longitude": 0.0, "hysteresis_m": -1.0}, "hysteresis_m"),
        ],
    )
    def test_rejects_impossible_values(
        self,
        kwargs: dict[str, float],
        expected: str,
    ) -> None:
        """Out-of-range coordinates and distances raise, naming the bad field."""
        with pytest.raises(PolicyError, match=expected):
            HomeLocation(**kwargs)

    def test_accepts_boundary_coordinates(self) -> None:
        """The poles and the antimeridian are valid places."""
        assert HomeLocation(latitude=90.0, longitude=180.0).latitude == 90.0
        assert HomeLocation(latitude=-90.0, longitude=-180.0).longitude == -180.0

    def test_distance_to_self_is_zero(self) -> None:
        """A point measured against itself is zero metres away."""
        assert HOME.distance_m(HOME.latitude, HOME.longitude) == pytest.approx(0.0)

    def test_distance_matches_known_offset(self) -> None:
        """One degree of latitude is ~111 km; used to pin the Haversine maths."""
        away = HOME.distance_m(HOME.latitude + 1.0, HOME.longitude)
        assert away == pytest.approx(METRES_PER_DEGREE_LAT, rel=0.01)

    def test_inside_within_radius_regardless_of_state(self) -> None:
        """Well inside the radius is "home" whether or not focus is already on."""
        near = HOME.latitude + 50 / METRES_PER_DEGREE_LAT
        assert HOME.is_inside(near, HOME.longitude, currently_focused=False)
        assert HOME.is_inside(near, HOME.longitude, currently_focused=True)

    def test_hysteresis_prevents_flapping_at_the_boundary(self) -> None:
        """Between radius and radius+hysteresis the answer depends on state.

        This is the whole point of hysteresis: arriving has not yet triggered
        focus, but leaving has not yet released it, so GPS jitter around the
        boundary cannot toggle enforcement on every poll.
        """
        edge = HOME.latitude + 160 / METRES_PER_DEGREE_LAT
        assert not HOME.is_inside(edge, HOME.longitude, currently_focused=False)
        assert HOME.is_inside(edge, HOME.longitude, currently_focused=True)

    def test_outside_hysteresis_band_is_away_in_both_states(self) -> None:
        """Beyond radius+hysteresis the user is away regardless of state."""
        far = HOME.latitude + 500 / METRES_PER_DEGREE_LAT
        assert not HOME.is_inside(far, HOME.longitude, currently_focused=False)
        assert not HOME.is_inside(far, HOME.longitude, currently_focused=True)


class TestCurfewWindow:
    """Window containment, including the midnight wrap."""

    @pytest.mark.parametrize(
        ("moment", "expected"),
        [
            (time(22, 59), False),
            (time(23, 0), True),
            (time(23, 59), True),
            (time(0, 0), True),
            (time(4, 59), True),
            (time(5, 0), False),
            (time(12, 0), False),
        ],
    )
    def test_wrapping_window_spans_midnight(
        self,
        moment: time,
        *,
        expected: bool,
    ) -> None:
        """23:00-05:00 covers the late evening and the small hours alike."""
        window = CurfewWindow(start=time(23, 0), end=time(5, 0))
        assert window.contains(moment) is expected

    @pytest.mark.parametrize(
        ("moment", "expected"),
        [
            (time(8, 59), False),
            (time(9, 0), True),
            (time(16, 59), True),
            (time(17, 0), False),
        ],
    )
    def test_same_day_window(self, moment: time, *, expected: bool) -> None:
        """A non-wrapping window is a plain half-open interval."""
        window = CurfewWindow(start=time(9, 0), end=time(17, 0))
        assert window.contains(moment) is expected
