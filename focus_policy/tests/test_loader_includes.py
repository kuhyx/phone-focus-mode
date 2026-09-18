"""``read_config_text``: the loader follows config.sh's sibling includes.

config.sh was split on 2026-09-18 (WHITELIST and NIGHT_WHITELIST moved to
config_whitelist.sh). The shell sees one namespace through ``.``; these tests
pin that the parser sees the same one, and that the two ways this could go
quietly wrong -- a missing sibling read as "no allowlist", or the optional
secrets include treated as mandatory -- are loud instead.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from focus_policy.loader import load_policy, read_config_text
from focus_policy.model import PolicyError

REPO_ROOT = Path(__file__).resolve().parents[2]

_BASE = """
export HOME_LAT=52.0
export HOME_LON=21.0
export LAUNCHER_PACKAGE=com.launcher
. "$SCRIPT_DIR/config_lists.sh"
if [ -f "$SCRIPT_DIR/config_secrets.sh" ]; then
\t. "$SCRIPT_DIR/config_secrets.sh"
fi
"""

_LISTS = """
export WHITELIST="
com.launcher
com.example.day
"
export NIGHT_WHITELIST="
com.launcher
"
"""


def _write(tmp_path: Path, *, lists: str | None = _LISTS) -> Path:
    config = tmp_path / "config.sh"
    config.write_text(_BASE, encoding="utf-8")
    if lists is not None:
        (tmp_path / "config_lists.sh").write_text(lists, encoding="utf-8")
    return config


def test_lists_from_a_sourced_sibling_reach_the_policy(tmp_path: Path) -> None:
    policy = load_policy(_write(tmp_path))

    assert policy.allowed_packages == frozenset({"com.launcher", "com.example.day"})
    assert policy.night_allowed_packages == frozenset({"com.launcher"})


def test_the_indented_optional_secrets_include_is_not_followed(tmp_path: Path) -> None:
    """No config_secrets.sh exists here; the guarded include must be ignored."""
    text = read_config_text(_write(tmp_path))

    assert "config_secrets.sh" in text  # left in place, not spliced
    assert "com.example.day" in text  # the unconditional include was spliced


def test_a_missing_sibling_is_an_error_not_an_empty_allowlist(tmp_path: Path) -> None:
    with pytest.raises(PolicyError, match="config_lists.sh, which does not exist"):
        load_policy(_write(tmp_path, lists=None))


def test_includes_that_cycle_are_refused(tmp_path: Path) -> None:
    (tmp_path / "config.sh").write_text(
        '. "$SCRIPT_DIR/config_b.sh"\n', encoding="utf-8"
    )
    (tmp_path / "config_b.sh").write_text(
        '. "$SCRIPT_DIR/config.sh"\n', encoding="utf-8"
    )

    with pytest.raises(PolicyError, match="cycle"):
        read_config_text(tmp_path / "config.sh")


def test_nested_includes_are_followed(tmp_path: Path) -> None:
    (tmp_path / "config.sh").write_text('. "$SCRIPT_DIR/a.sh"\n', encoding="utf-8")
    (tmp_path / "a.sh").write_text(
        'export X=1\n. "$SCRIPT_DIR/b.sh"\n', encoding="utf-8"
    )
    (tmp_path / "b.sh").write_text("export Y=2\n", encoding="utf-8")

    text = read_config_text(tmp_path / "config.sh")

    assert "export X=1" in text
    assert "export Y=2" in text


def test_the_real_config_resolves_its_allowlists_through_the_split() -> None:
    """The regression this split could cause: WHITELIST silently empty."""
    text = read_config_text(REPO_ROOT / "config.sh")

    assert 'export WHITELIST="' in text
    assert 'export NIGHT_WHITELIST="' in text
    assert 'export RETHINK_BLOCK_DOMAINS="' in text
