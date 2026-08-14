"""Typed policy model shared by every focus-mode enforcement backend.

The rooted implementation expresses all of this as exported shell strings in
``phone_focus_mode/config.sh``. That works for shell, but it cannot be unit
tested, and a Device Owner app written in Kotlin cannot read it at all. This
module is the language-neutral source of truth; ``export_json`` renders it into
a form any backend can load.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Sequence
    from datetime import time


_MAX_LATITUDE = 90.0
_MAX_LONGITUDE = 180.0
_EARTH_RADIUS_M = 6_371_000.0


class PolicyError(ValueError):
    """Raised when a policy value is missing, malformed, or self-contradictory."""


@dataclass(frozen=True)
class HomeLocation:
    """The coordinate that focus mode is anchored to.

    ``radius_m`` is the distance at which restrictions switch on.
    ``hysteresis_m`` is added to the radius before restrictions switch back
    *off*, so that GPS jitter at exactly the boundary cannot cause the enforcer
    to flap between states many times a minute.
    """

    latitude: float
    longitude: float
    radius_m: float = 150.0
    hysteresis_m: float = 30.0

    def __post_init__(self) -> None:
        """Reject coordinates and distances that cannot describe a real place."""
        if not -_MAX_LATITUDE <= self.latitude <= _MAX_LATITUDE:
            msg = f"latitude {self.latitude} outside [-90, 90]"
            raise PolicyError(msg)
        if not -_MAX_LONGITUDE <= self.longitude <= _MAX_LONGITUDE:
            msg = f"longitude {self.longitude} outside [-180, 180]"
            raise PolicyError(msg)
        if self.radius_m <= 0:
            msg = f"radius_m must be positive, got {self.radius_m}"
            raise PolicyError(msg)
        if self.hysteresis_m < 0:
            msg = f"hysteresis_m must not be negative, got {self.hysteresis_m}"
            raise PolicyError(msg)

    def distance_m(self, latitude: float, longitude: float) -> float:
        """Return great-circle metres from home to the given point.

        Mirrors the Haversine formula in ``focus_daemon.sh`` so that the Python
        policy layer and the shell enforcer agree on the same boundary.
        """
        lat1, lat2 = math.radians(self.latitude), math.radians(latitude)
        delta_lat = math.radians(latitude - self.latitude)
        delta_lon = math.radians(longitude - self.longitude)
        haversine = (
            math.sin(delta_lat / 2) ** 2
            + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
        )
        return 2 * _EARTH_RADIUS_M * math.asin(math.sqrt(haversine))

    def is_inside(
        self,
        latitude: float,
        longitude: float,
        *,
        currently_focused: bool,
    ) -> bool:
        """Return whether this point counts as "at home", honouring hysteresis.

        The threshold depends on the current state: leaving requires travelling
        ``hysteresis_m`` further than arriving did. Without this a reading that
        hovers on the radius toggles enforcement on every poll.
        """
        threshold = self.radius_m + (self.hysteresis_m if currently_focused else 0.0)
        return self.distance_m(latitude, longitude) <= threshold


@dataclass(frozen=True)
class CurfewWindow:
    """A nightly window that wraps midnight (e.g. 23:00 -> 05:00)."""

    start: time
    end: time

    def contains(self, moment: time) -> bool:
        """Return whether ``moment`` falls inside the window.

        Handles both same-day windows (09:00-17:00) and the wrapping windows
        focus mode actually uses (23:00-05:00), where "inside" means at or after
        the start *or* strictly before the end.
        """
        if self.start <= self.end:
            return self.start <= moment < self.end
        return moment >= self.start or moment < self.end


@dataclass(frozen=True)
class FocusPolicy:
    """The complete, backend-independent focus-mode policy."""

    home: HomeLocation
    allowed_packages: frozenset[str]
    night_allowed_packages: frozenset[str]
    never_disable_prefixes: tuple[str, ...]
    workout_unblock_domains: frozenset[str] = frozenset()
    curfew: CurfewWindow | None = None
    launcher_package: str | None = None
    browser_packages: frozenset[str] = field(default_factory=frozenset)
    # Prefix-matched allowlists, for apps that ship as a family of packages.
    # Tachiyomi installs every source as its own apk, so an exact list goes
    # stale the moment a new extension is installed.
    allowed_prefixes: tuple[str, ...] = ()
    night_allowed_prefixes: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        """Reject policies that would lock the user out of the device."""
        if self.launcher_package and self.launcher_package not in self.allowed_packages:
            msg = (
                f"launcher {self.launcher_package!r} is not in allowed_packages; "
                "enforcing this policy would leave the device with no home screen"
            )
            raise PolicyError(msg)
        orphans = self.night_allowed_packages - self.allowed_packages
        if orphans:
            msg = (
                "night_allowed_packages must be a subset of allowed_packages; "
                f"unknown at day level: {sorted(orphans)}"
            )
            raise PolicyError(msg)
        # Same subset rule as the package lists: the curfew is meant to be a
        # tightening of the day policy, so a prefix allowed only at night would
        # invert that and be easy to miss in review.
        prefix_orphans = set(self.night_allowed_prefixes) - set(self.allowed_prefixes)
        if prefix_orphans:
            msg = (
                "night_allowed_prefixes must be a subset of allowed_prefixes; "
                f"unknown at day level: {sorted(prefix_orphans)}"
            )
            raise PolicyError(msg)

    @staticmethod
    def _matches_prefix(package: str, prefixes: Sequence[str]) -> bool:
        """Return whether ``package`` is covered by any entry of ``prefixes``.

        Matched on whole labels, so ``com.android.providers`` covers
        ``com.android.providers.telephony`` but not
        ``com.android.providersomething``. Shared by every prefix list so the
        boundary rule cannot drift between them.
        """
        return any(
            package == prefix or package.startswith(f"{prefix}.") for prefix in prefixes
        )

    def is_protected(self, package: str) -> bool:
        """Return whether a package must never be disabled.

        Guards the system packages whose loss would brick core functions —
        dialer, settings, IME, SystemUI. Prefix-matched, mirroring the shell
        implementation, so that ``com.android.providers.telephony`` is covered
        by the ``com.android.providers`` entry.
        """
        return self._matches_prefix(package, self.never_disable_prefixes)

    def is_allowed(self, package: str, *, during_curfew: bool = False) -> bool:
        """Return whether a package may run under the given conditions.

        Protected system packages are always allowed. During curfew the much
        smaller ``night_allowed_packages`` set applies instead of the day list,
        and likewise for the prefix lists.
        """
        if self.is_protected(package):
            return True
        if during_curfew:
            return package in self.night_allowed_packages or self._matches_prefix(
                package,
                self.night_allowed_prefixes,
            )
        return package in self.allowed_packages or self._matches_prefix(
            package,
            self.allowed_prefixes,
        )

    def is_curfew_active(self, moment: time) -> bool:
        """Return whether the night curfew is in force at ``moment``."""
        return self.curfew is not None and self.curfew.contains(moment)

    def packages_to_block(
        self,
        installed: frozenset[str],
        *,
        during_curfew: bool = False,
    ) -> frozenset[str]:
        """Return the installed packages that this policy blocks.

        Callers pass the set actually present on the device, so a package that
        is not installed never appears in the result.
        """
        return frozenset(
            package
            for package in installed
            if not self.is_allowed(package, during_curfew=during_curfew)
        )
