"""Gate: kuhy's own game stays allowed in every policy tier.

kuhy asked on 2026-10-03 for Kado no Akari (`com.kadonoakari.game`) to be
"whitelisted permanently everywhere and always". It is not under the
com.kuhy / dev.kuhy prefixes, and the workday-lockdown tier ignores prefixes
entirely, so only exact entries in all three lists keep it visible -- and the
lists have been rewritten wholesale before (2026-08-11). A comment would not
survive the next rewrite; this test does.
"""

from __future__ import annotations

import pathlib

from focus_policy.loader import load_policy

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config.sh"

GAME = "com.kadonoakari.game"


def _policy(tmp_path: pathlib.Path):
    """Load the real config.sh with throwaway coordinates (unused here)."""
    secrets = tmp_path / "config_secrets.sh"
    secrets.write_text("export HOME_LAT=52.0\nexport HOME_LON=21.0\n", encoding="utf-8")
    return load_policy(CONFIG, secrets)


def test_game_is_exact_listed_in_every_tier(tmp_path: pathlib.Path) -> None:
    """Day, curfew and lockdown lists each name the game exactly."""
    policy = _policy(tmp_path)
    assert GAME in policy.allowed_packages
    assert GAME in policy.night_allowed_packages
    assert policy.lockdown_allowed_packages is not None
    assert GAME in policy.lockdown_allowed_packages


def test_game_is_allowed_day_and_night(tmp_path: pathlib.Path) -> None:
    """The decision itself, not just list membership, allows it."""
    policy = _policy(tmp_path)
    assert policy.is_allowed(GAME)
    assert policy.is_allowed(GAME, during_curfew=True)


def test_game_is_never_night_blocked(tmp_path: pathlib.Path) -> None:
    """NIGHT_BLOCKED_PACKAGES would beat the night list, so it must not hold it."""
    assert GAME not in _policy(tmp_path).night_blocked_packages
