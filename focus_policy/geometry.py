"""Home-location and curfew-window value types.

Split out of ``model.py`` for the 250-line cap (2026-09-23), the same reason
``config.sh`` and several Kotlin files in this repo are split into siblings.
Nothing here changed behaviour; ``model.py`` re-exports both names so every
existing ``from focus_policy.model import ...`` keeps working.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
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
