"""Gate: exactly one FOSS browser (Fennec F-Droid) is allowed, by day only.

kuhy approved this on 2026-11-01 so his Flutter apps can open a Google OAuth
sign-in page (PKCE, Custom Tab / VIEW intent). With every browser hidden no
activity resolved an https VIEW intent at all. The exception must stay ONE
package wide: Chrome stays hidden, and the curfew stays browser-free.
"""

from __future__ import annotations

import json
import pathlib

from focus_policy.loader import load_policy

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config.sh"
ASSET = REPO_ROOT / "focus-owner" / "assets" / "policy.json"

FENNEC = "org.mozilla.fennec_fdroid"
OTHER_BROWSERS = ("com.android.chrome", "org.mozilla.fenix", "com.brave.browser")


def _policy(tmp_path: pathlib.Path):
    """Load the real config.sh with throwaway coordinates (unused here)."""
    secrets = tmp_path / "config_secrets.sh"
    secrets.write_text("export HOME_LAT=52.0\nexport HOME_LON=21.0\n", encoding="utf-8")
    return load_policy(CONFIG, secrets)


def test_fennec_allowed_by_day_not_at_night(tmp_path: pathlib.Path) -> None:
    """Day list names it exactly; the strictly tighter curfew list does not."""
    policy = _policy(tmp_path)
    assert FENNEC in policy.allowed_packages
    assert policy.is_allowed(FENNEC)
    assert not policy.is_allowed(FENNEC, during_curfew=True)


def test_no_other_browser_is_allowed(tmp_path: pathlib.Path) -> None:
    """The exception covers one package, not the category."""
    policy = _policy(tmp_path)
    for pkg in OTHER_BROWSERS:
        assert not policy.is_allowed(pkg), pkg


def test_asset_allows_fennec_and_blocks_the_rest() -> None:
    """The shipped asset agrees: Fennec allowed, never also always-blocked."""
    asset = json.loads(ASSET.read_text(encoding="utf-8"))
    assert FENNEC in asset["allowed_packages"]
    assert FENNEC not in asset["night_allowed_packages"]
    assert FENNEC not in asset["always_blocked_packages"]
    assert FENNEC not in asset["browser_packages"]
    assert "com.android.chrome" in asset["always_blocked_packages"]
    assert "com.android.chrome" not in asset["allowed_packages"]
