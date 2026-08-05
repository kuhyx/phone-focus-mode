"""Device-independent focus-mode policy.

This package holds the *policy* half of phone focus mode: which packages are
allowed, how close to home counts as "at home", when the night curfew runs, and
which domains a workout temporarily unblocks.

It deliberately contains no enforcement code and no Android calls. The rooted
shell implementation (``phone_focus_mode/``) and the future unrooted Device
Owner app consume the same policy from here, so the two can never drift.
"""

from __future__ import annotations

from python_pkg.focus_policy.model import (
    CurfewWindow,
    FocusPolicy,
    HomeLocation,
    PolicyError,
)

__all__ = [
    "CurfewWindow",
    "FocusPolicy",
    "HomeLocation",
    "PolicyError",
]
