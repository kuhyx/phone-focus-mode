"""Tests for phone_focus_mode/strip_workout_hosts.py (hosts workout variant)."""

from __future__ import annotations

from typing import TYPE_CHECKING

import strip_workout_hosts
from strip_workout_hosts import _strip, main

if TYPE_CHECKING:
    from pathlib import Path

    import pytest

_HOSTS = """\
# header
127.0.0.1 localhost
0.0.0.0 youtube.com www.youtube.com
0.0.0.0 ads.example.com
0.0.0.0 m.youtube.com alias.youtube.com
0.0.0.0 keepme.com
"""


def _src(tmp_path: Path) -> Path:
    """Write the sample hosts file and return its path."""
    path = tmp_path / "hosts"
    path.write_text(_HOSTS, encoding="utf-8")
    return path


class TestStrip:
    """``_strip`` removes lines mapping unblocked domains."""

    def test_removes_matching_and_alias_lines(self, tmp_path: Path) -> None:
        """Entries whose name or any alias is unblocked are dropped."""
        dest = tmp_path / "out"
        _strip(
            _src(tmp_path),
            dest,
            frozenset({"youtube.com", "www.youtube.com", "m.youtube.com"}),
        )
        result = dest.read_text(encoding="utf-8")
        assert "youtube.com" not in result  # both youtube entries gone
        assert "ads.example.com" in result
        assert "keepme.com" in result
        assert "localhost" in result
        assert "# header" in result

    def test_empty_unblock_keeps_everything(self, tmp_path: Path) -> None:
        """An empty unblock set copies the file verbatim."""
        dest = tmp_path / "out"
        _strip(_src(tmp_path), dest, frozenset())
        assert dest.read_text(encoding="utf-8") == _HOSTS

    def test_comment_and_blank_lines_preserved(self, tmp_path: Path) -> None:
        """Comment and blank lines are never stripped."""
        src = tmp_path / "hosts"
        src.write_text("# c\n\n0.0.0.0 block.me\n", encoding="utf-8")
        dest = tmp_path / "out"
        _strip(src, dest, frozenset({"block.me"}))
        assert dest.read_text(encoding="utf-8") == "# c\n\n"


class TestMain:
    """The CLI reads paths from argv and domains from the environment."""

    def test_bad_arg_count_returns_2(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A wrong number of path arguments is a usage error (rc 2)."""
        monkeypatch.setattr(
            strip_workout_hosts.sys, "argv", ["strip_workout_hosts", "only-one"]
        )
        assert main() == 2

    def test_strips_via_env(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Domains from the env var drive the stripping."""
        src = _src(tmp_path)
        dest = tmp_path / "out"
        monkeypatch.setenv("WORKOUT_UNBLOCK_DOMAINS", "youtube.com m.youtube.com")
        monkeypatch.setattr(
            strip_workout_hosts.sys,
            "argv",
            ["strip_workout_hosts", str(src), str(dest)],
        )
        assert main() == 0
        result = dest.read_text(encoding="utf-8")
        assert "www.youtube.com" not in result
        assert "keepme.com" in result
