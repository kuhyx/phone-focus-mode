#!/usr/bin/env python3
"""Render or grade a phone-monitoring report produced by ``monitor.sh``.

Two modes, selected by ``argv[1]``:

* ``summary`` — print a human-readable status summary to stdout (always exit 0).
* ``severity`` — exit 1 if any check is ``fatal``/``error``, else exit 0 (no output).

``argv[2]`` is the path to the ``report.json`` snapshot. Kept as a standalone
module (not inline ``python <<PY`` in ``monitor.sh``) so the repository's Python
tooling applies; see CLAUDE.md "Shell Style".
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

# Status buckets shown in the summary header, in display order.
_COUNT_KEYS = ("ok", "warn", "error", "fatal")
# Statuses considered problems worth listing / failing on.
_ISSUE_STATUSES = frozenset({"warn", "error", "fatal"})
_SEVERE_STATUSES = frozenset({"error", "fatal"})


def _load_checks(report_path: Path) -> list[object]:
    """Return the ``checks`` array from the report, or [] if absent/malformed."""
    data: object = json.loads(report_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return []
    checks: object = data.get("checks", [])
    return checks if isinstance(checks, list) else []


def _field(check: object, key: str, default: str) -> str:
    """Read a string field from a check object, falling back to ``default``."""
    if isinstance(check, dict):
        value = check.get(key, default)
        if isinstance(value, str):
            return value
    return default


def _render_summary(checks: list[object]) -> str:
    """Build the multi-line monitoring summary string for the given checks."""
    counts = dict.fromkeys(_COUNT_KEYS, 0)
    issues: list[tuple[str, str, str]] = []
    for check in checks:
        status = _field(check, "status", "warn")
        counts[status] = counts.get(status, 0) + 1
        if status in _ISSUE_STATUSES:
            issues.append(
                (
                    status,
                    _field(check, "check", "unknown"),
                    _field(check, "message", ""),
                ),
            )

    lines = [
        "",
        "=== Monitoring Summary ===",
        f"  ok={counts.get('ok', 0):<3}  warn={counts.get('warn', 0):<3}  "
        f"error={counts.get('error', 0):<3}  fatal={counts.get('fatal', 0):<3}",
    ]
    if issues:
        lines.append("")
        lines.append("Issues found:")
        lines.extend(
            f"  [{status}] {name}: {message}" for status, name, message in issues
        )
    lines.append("==========================")
    lines.append("")
    return "\n".join(lines) + "\n"


def _has_severe(checks: list[object]) -> bool:
    """Return True if any check has a fatal/error status."""
    return any(_field(check, "status", "warn") in _SEVERE_STATUSES for check in checks)


def main() -> int:
    """Dispatch on ``argv[1]`` (summary|severity) and ``argv[2]`` (report path)."""
    args = sys.argv[1:]
    expected_args = 2
    if len(args) != expected_args or args[0] not in {"summary", "severity"}:
        sys.stderr.write("usage: monitor_report.py {summary|severity} <report.json>\n")
        return 2
    mode, report_path = args[0], Path(args[1])
    checks = _load_checks(report_path)
    if mode == "summary":
        sys.stdout.write(_render_summary(checks))
        return 0
    return 1 if _has_severe(checks) else 0


if __name__ == "__main__":
    sys.exit(main())
