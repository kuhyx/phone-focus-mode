"""Gate: the committed policy.json still matches config.sh.

`focus-owner/assets/policy.json` is generated from `config.sh`, but nothing
rebuilds it -- `focus-owner/pubspec.yaml` says so, and git history shows the two
have been edited independently (efda7f4 touched only the asset, a7c1287 only
config.sh). CI never compared them: it runs the generator against fixtures.

That gap is silent in the worst direction. `config.sh` is what a human reads and
reviews, but the phone enforces the asset, so a forgotten regeneration means the
policy says one thing and the device does another with nothing to flag it.
"""

from __future__ import annotations

import json
import pathlib

from focus_policy.export import policy_to_json
from focus_policy.loader import load_policy

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config.sh"
ASSET = REPO_ROOT / "focus-owner" / "assets" / "policy.json"

REGENERATE = (
    "python3 -m focus_policy --config config.sh --secrets <secrets> "
    "--redact-home --output focus-owner/assets/policy.json"
)


def test_committed_policy_matches_config(tmp_path: pathlib.Path) -> None:
    """Regenerating from config.sh reproduces the committed asset.

    Coordinates come from a throwaway file: config_secrets.sh is untracked and
    absent in CI by design, and `--redact-home` blanks the coordinates *after*
    loading, so the rendered output is identical whatever values are supplied.
    """
    secrets = tmp_path / "config_secrets.sh"
    secrets.write_text("export HOME_LAT=52.0\nexport HOME_LON=21.0\n", encoding="utf-8")

    expected = policy_to_json(load_policy(CONFIG, secrets), redact_home=True)
    committed = ASSET.read_text(encoding="utf-8")

    # Compare parsed objects, not bytes: key order or a trailing newline
    # differing would be a spurious failure, not real drift.
    assert json.loads(committed) == json.loads(expected), (
        "focus-owner/assets/policy.json is out of date with config.sh. "
        f"Regenerate it with:\n    {REGENERATE}"
    )


def test_committed_policy_carries_no_home_coordinates() -> None:
    """The committed asset stays redacted; the real location is untracked."""
    data = json.loads(ASSET.read_text(encoding="utf-8"))
    home = data.get("home", {})
    assert not home.get("latitude")
    assert not home.get("longitude")
