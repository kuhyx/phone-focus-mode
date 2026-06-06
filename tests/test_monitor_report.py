"""Tests for phone_focus_mode/lib/monitor_report.py (report summary/severity)."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

import monitor_report
from monitor_report import _field, _has_severe, _load_checks, _render_summary, main

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def _write(tmp_path: Path, obj: object) -> Path:
    """Write ``obj`` as JSON to a temp file and return its path."""
    path = tmp_path / "report.json"
    path.write_text(json.dumps(obj), encoding="utf-8")
    return path


class TestLoadChecks:
    """``_load_checks`` tolerates malformed reports."""

    def test_reads_checks(self, tmp_path: Path) -> None:
        """A well-formed report yields its checks list."""
        path = _write(tmp_path, {"checks": [{"status": "ok"}]})
        assert _load_checks(path) == [{"status": "ok"}]

    def test_non_dict_report_yields_empty(self, tmp_path: Path) -> None:
        """A non-object report yields no checks."""
        assert _load_checks(_write(tmp_path, [1, 2])) == []

    def test_non_list_checks_yields_empty(self, tmp_path: Path) -> None:
        """A non-list ``checks`` value yields no checks."""
        assert _load_checks(_write(tmp_path, {"checks": "nope"})) == []


class TestField:
    """``_field`` reads string fields with a default."""

    def test_reads_present_string(self) -> None:
        """A present string field is returned."""
        assert _field({"status": "ok"}, "status", "warn") == "ok"

    def test_default_when_missing(self) -> None:
        """A missing field falls back to the default."""
        assert _field({}, "status", "warn") == "warn"

    def test_default_when_not_string(self) -> None:
        """A non-string field falls back to the default."""
        assert _field({"status": 5}, "status", "warn") == "warn"

    def test_default_when_check_not_dict(self) -> None:
        """A non-dict check falls back to the default."""
        assert _field("nope", "status", "warn") == "warn"


class TestRenderSummary:
    """``_render_summary`` produces the counts header and issue list."""

    def test_counts_and_issues(self) -> None:
        """Counts and a per-issue line are rendered."""
        checks: list[object] = [
            {"status": "ok", "check": "a", "message": ""},
            {"status": "warn", "check": "b", "message": "drift"},
            {"status": "error", "check": "c", "message": "boom"},
        ]
        out = _render_summary(checks)
        assert "ok=1" in out
        assert "warn=1" in out
        assert "error=1" in out
        assert "[warn] b: drift" in out
        assert "[error] c: boom" in out

    def test_no_issues_section_when_all_ok(self) -> None:
        """With no problems, the issues section is omitted."""
        out = _render_summary([{"status": "ok", "check": "a", "message": ""}])
        assert "Issues found:" not in out
        # Footer line plus a trailing blank line, matching the original output.
        assert out.endswith("==========================\n\n")


class TestHasSevere:
    """``_has_severe`` flags fatal/error checks."""

    def test_true_for_error(self) -> None:
        """An error status is severe."""
        assert _has_severe([{"status": "error"}]) is True

    def test_true_for_fatal(self) -> None:
        """A fatal status is severe."""
        assert _has_severe([{"status": "fatal"}]) is True

    def test_false_for_ok_warn(self) -> None:
        """ok/warn statuses are not severe."""
        assert _has_severe([{"status": "ok"}, {"status": "warn"}]) is False


class TestMain:
    """The CLI dispatches on mode and reports severity via exit code."""

    def test_bad_usage_returns_2(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An unknown mode is a usage error (rc 2)."""
        monkeypatch.setattr(
            monitor_report.sys, "argv", ["monitor_report", "bogus", "x"]
        )
        assert main() == 2

    def test_summary_prints_and_returns_0(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Summary mode prints the report and returns 0."""
        path = _write(
            tmp_path, {"checks": [{"status": "warn", "check": "b", "message": "m"}]}
        )
        monkeypatch.setattr(
            monitor_report.sys,
            "argv",
            ["monitor_report", "summary", str(path)],
        )
        assert main() == 0
        assert "Monitoring Summary" in capsys.readouterr().out

    def test_severity_returns_1_on_error(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Severity mode returns 1 when a severe check exists."""
        path = _write(tmp_path, {"checks": [{"status": "error"}]})
        monkeypatch.setattr(
            monitor_report.sys,
            "argv",
            ["monitor_report", "severity", str(path)],
        )
        assert main() == 1

    def test_severity_returns_0_when_clean(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Severity mode returns 0 when no severe check exists."""
        path = _write(tmp_path, {"checks": [{"status": "ok"}]})
        monkeypatch.setattr(
            monitor_report.sys,
            "argv",
            ["monitor_report", "severity", str(path)],
        )
        assert main() == 0
