"""Tests for the policy-export command line entry point."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

import pytest

from python_pkg.focus_policy.__main__ import build_parser, main

if TYPE_CHECKING:
    from pathlib import Path

MINIMAL_CONFIG = """
export RADIUS=150
export NIGHT_CURFEW_ENABLED=1
export NIGHT_CURFEW_START="2300"
export NIGHT_CURFEW_END="0500"
export LAUNCHER_PACKAGE="com.launcher"
export WHITELIST="
com.launcher
pl.mbank
"
export NIGHT_WHITELIST="
pl.mbank
"
export SYSTEM_NEVER_DISABLE="
com.android.settings
"
"""

SECRETS = "export HOME_LAT=52.2297\nexport HOME_LON=21.0122\n"


@pytest.fixture
def config(tmp_path: Path) -> Path:
    """Write a minimal config plus secrets, returning the config path."""
    (tmp_path / "config.sh").write_text(MINIMAL_CONFIG, encoding="utf-8")
    (tmp_path / "config_secrets.sh").write_text(SECRETS, encoding="utf-8")
    return tmp_path / "config.sh"


def test_parser_requires_config() -> None:
    """--config is mandatory; without it argparse exits."""
    with pytest.raises(SystemExit):
        build_parser().parse_args([])


def test_writes_policy_to_stdout(
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """With no --output the rendered policy goes to stdout."""
    assert main(["--config", str(config)]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["schema_version"] == 1
    assert payload["home"]["latitude"] == pytest.approx(52.2297)


def test_writes_policy_to_file(config: Path, tmp_path: Path) -> None:
    """--output writes the document, creating parent directories."""
    out = tmp_path / "nested" / "policy.json"
    assert main(["--config", str(config), "--output", str(out)]) == 0
    assert json.loads(out.read_text(encoding="utf-8"))["schema_version"] == 1


def test_redact_home_removes_coordinates(
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """--redact-home blanks the coordinates but keeps the radius.

    This is the flag the committed asset is generated with, so that the
    repository never records where the user lives.
    """
    assert main(["--config", str(config), "--redact-home"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["home"]["latitude"] is None
    assert payload["home"]["longitude"] is None
    assert payload["home"]["radius_m"] == pytest.approx(150.0)


def test_explicit_secrets_path(config: Path, tmp_path: Path) -> None:
    """--secrets overrides the default sibling lookup."""
    other = tmp_path / "other.sh"
    other.write_text("export HOME_LAT=1.0\nexport HOME_LON=2.0\n", encoding="utf-8")
    assert main(["--config", str(config), "--secrets", str(other)]) == 0


def test_placeholder_coordinates_exit_nonzero(
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The shipped placeholder is a hard error, not a silent default."""
    config.with_name("config_secrets.sh").write_text(
        "export HOME_LAT=REDACTED_LAT\nexport HOME_LON=REDACTED_LON\n",
        encoding="utf-8",
    )
    assert main(["--config", str(config)]) == 1
    assert "placeholder" in capsys.readouterr().err


def test_missing_config_exits_nonzero(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An unreadable config reports the OS error rather than traceback."""
    assert main(["--config", str(tmp_path / "absent.sh")]) == 1
    assert "error:" in capsys.readouterr().err
