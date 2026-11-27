"""Gate: no ``"`` inside the quoted allowlists of ``config_whitelist.sh``.

Each list is one double-quoted bash string with comment lines inside it, so a
``"`` in a comment ends the string early and silently drops every package after
it (2026-11-27: a quoted remark cut 18 apps out of the day list). Only the
opening ``export X="`` and the closing ``"`` line may hold one.
"""

from __future__ import annotations

import pathlib
import re

CONFIG = pathlib.Path(__file__).resolve().parent.parent / "config_whitelist.sh"
OPEN = re.compile(r'^export [A-Z_]+="$')


def test_no_quote_inside_a_quoted_list() -> None:
    inside, bad = False, []
    for number, line in enumerate(CONFIG.read_text(encoding="utf-8").splitlines(), 1):
        if not inside:
            inside = bool(OPEN.match(line))
        elif line.strip() == '"':
            inside = False
        elif '"' in line:
            bad.append(number)
    assert not inside, "a list was never closed"
    assert bad == []
