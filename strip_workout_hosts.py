#!/usr/bin/env python3
"""Produce the workout variant of the canonical hosts file.

Copies ``argv[1]`` (the full hosts file) to ``argv[2]``, dropping every entry
whose host name (or any alias) matches a workout-allowlisted domain. The domain
set is read from the ``WORKOUT_UNBLOCK_DOMAINS`` environment variable (whitespace
separated) so the generator and the on-device runtime share one source of truth.

Kept as a standalone module (not inline ``python <<PY`` in ``deploy.sh``) so the
repository's Python tooling applies; see CLAUDE.md "Shell Style".
"""

from __future__ import annotations

import os
from pathlib import Path
import sys

# A hosts entry needs at least an IP and one name: "<ip> <name> [aliases...]".
_MIN_HOSTS_FIELDS = 2


def _strip(source: Path, dest: Path, unblock: frozenset[str]) -> None:
    """Write ``source`` to ``dest`` minus lines that map an unblocked domain."""
    text = source.read_text(encoding="utf-8", errors="replace")
    kept: list[str] = []
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            kept.append(line)
            continue
        parts = stripped.split()
        names = parts[1:]
        if len(parts) >= _MIN_HOSTS_FIELDS and any(
            name.lower() in unblock for name in names
        ):
            continue
        kept.append(line)
    dest.write_text("".join(kept), encoding="utf-8")


def main() -> int:
    """Read the source/dest paths from argv and the domains from the env."""
    args = sys.argv[1:]
    expected_args = 2
    if len(args) != expected_args:
        sys.stderr.write("usage: strip_workout_hosts.py <src-hosts> <dst-hosts>\n")
        return 2
    unblock = frozenset(os.environ.get("WORKOUT_UNBLOCK_DOMAINS", "").split())
    _strip(Path(args[0]), Path(args[1]), unblock)
    return 0


if __name__ == "__main__":
    sys.exit(main())
