"""Load the focus-mode policy from the shell config that already exists.

``phone_focus_mode/config.sh`` is the live source of truth for the rooted
enforcer. Rather than copy its lists into Python — where they would silently
drift the first time either side is edited — this module parses them.

Only simple ``export NAME="..."`` assignments are read. This is not a shell
interpreter: it deliberately understands the narrow subset ``config.sh`` uses
for policy, and raises rather than guessing at anything else.
"""

from __future__ import annotations

from datetime import time
import re
from typing import TYPE_CHECKING

from python_pkg.focus_policy.model import (
    CurfewWindow,
    FocusPolicy,
    HomeLocation,
    PolicyError,
)

if TYPE_CHECKING:
    from pathlib import Path

# Matches `export NAME="value"` / `NAME='value'` / `NAME=bare`, including the
# multi-line quoted blocks config.sh uses for its package lists.
_ASSIGNMENT = re.compile(
    r"^\s*(?:export\s+|readonly\s+)*(?P<name>[A-Za-z_][A-Za-z0-9_]*)="
    r"(?P<value>\"[^\"]*\"|'[^']*'|\S*)",
    re.MULTILINE | re.DOTALL,
)

_HHMM_LEN = 4

# A quoted value needs at least the opening and closing quote characters.
_MIN_QUOTED_LEN = 2


def parse_shell_assignments(text: str) -> dict[str, str]:
    """Return every simple assignment in ``text`` as a name -> value mapping.

    Later assignments win, matching shell semantics where re-assigning a name
    overwrites the earlier value.
    """
    values: dict[str, str] = {}
    for match in _ASSIGNMENT.finditer(text):
        raw = match.group("value")
        if (
            raw[:1] in {'"', "'"}
            and raw[-1:] == raw[:1]
            and len(raw) >= _MIN_QUOTED_LEN
        ):
            raw = raw[1:-1]
        values[match.group("name")] = raw
    return values


def parse_package_list(value: str) -> frozenset[str]:
    """Return the non-comment, non-blank entries of a whitespace-separated list."""
    return frozenset(
        line.strip()
        for line in value.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


def parse_hhmm(value: str, *, field_name: str) -> time:
    """Parse a bare ``HHMM`` string as used by ``NIGHT_CURFEW_START``/``_END``."""
    digits = value.strip()
    if len(digits) != _HHMM_LEN or not digits.isdigit():
        msg = f"{field_name} must be 4 digits (HHMM), got {value!r}"
        raise PolicyError(msg)
    hour, minute = int(digits[:2]), int(digits[2:])
    try:
        return time(hour=hour, minute=minute)
    except ValueError as exc:
        msg = f"{field_name} is not a valid time: {value!r}"
        raise PolicyError(msg) from exc


def _require(values: dict[str, str], name: str) -> str:
    """Return ``values[name]`` or raise a PolicyError naming the missing key."""
    try:
        return values[name]
    except KeyError as exc:
        msg = f"required setting {name} is missing"
        raise PolicyError(msg) from exc


def _coordinate(values: dict[str, str], name: str) -> float:
    """Return a coordinate, rejecting the shipped ``REDACTED_*`` placeholders.

    ``config_secrets.sh`` ships with placeholder coordinates so the real home
    location never lands in git. Parsing one as a float raises, but the failure
    reads as a generic type error; callers need to be told the file was never
    filled in. Defaulting to 0.0 would be worse still — it silently relocates
    "home" to the Atlantic and disables the location gate entirely.
    """
    raw = _require(values, name).strip()
    try:
        return float(raw)
    except ValueError as exc:
        msg = (
            f"{name} is {raw!r}, not a coordinate. Set the real value in "
            "config_secrets.sh (untracked); the shipped file is a placeholder."
        )
        raise PolicyError(msg) from exc


def _float_setting(values: dict[str, str], name: str, default: float) -> float:
    """Return a numeric setting, falling back to ``default`` when unset."""
    raw = values.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw)
    except ValueError as exc:
        msg = f"{name} must be numeric, got {raw!r}"
        raise PolicyError(msg) from exc


def load_policy(
    config_path: Path,
    secrets_path: Path | None = None,
) -> FocusPolicy:
    """Build a :class:`FocusPolicy` from ``config.sh`` and its secrets file.

    ``HOME_LAT``/``HOME_LON`` live in ``config_secrets.sh``, which is untracked
    because it pins down where the user lives. It is read from a separate path
    and never embedded in this repository.
    """
    values = parse_shell_assignments(config_path.read_text(encoding="utf-8"))

    if secrets_path is None:
        secrets_path = config_path.parent / "config_secrets.sh"
    if secrets_path.is_file():
        values.update(parse_shell_assignments(secrets_path.read_text(encoding="utf-8")))

    home = HomeLocation(
        latitude=_coordinate(values, "HOME_LAT"),
        longitude=_coordinate(values, "HOME_LON"),
        radius_m=_float_setting(values, "RADIUS", 150.0),
        hysteresis_m=_float_setting(values, "HYSTERESIS", 30.0),
    )

    curfew: CurfewWindow | None = None
    if values.get("NIGHT_CURFEW_ENABLED", "0").strip() == "1":
        curfew = CurfewWindow(
            start=parse_hhmm(
                _require(values, "NIGHT_CURFEW_START"),
                field_name="NIGHT_CURFEW_START",
            ),
            end=parse_hhmm(
                _require(values, "NIGHT_CURFEW_END"),
                field_name="NIGHT_CURFEW_END",
            ),
        )

    launcher = values.get("LAUNCHER_PACKAGE", "").strip() or None

    return FocusPolicy(
        home=home,
        allowed_packages=parse_package_list(_require(values, "WHITELIST")),
        night_allowed_packages=parse_package_list(values.get("NIGHT_WHITELIST", "")),
        never_disable_prefixes=tuple(
            sorted(parse_package_list(values.get("SYSTEM_NEVER_DISABLE", "")))
        ),
        workout_unblock_domains=parse_package_list(
            values.get("WORKOUT_UNBLOCK_DOMAINS", "")
        ),
        curfew=curfew,
        launcher_package=launcher,
        browser_packages=parse_package_list(values.get("BROWSER_PACKAGES", "")),
        allowed_prefixes=tuple(
            sorted(parse_package_list(values.get("ALLOWED_PREFIXES", "")))
        ),
        night_allowed_prefixes=tuple(
            sorted(parse_package_list(values.get("NIGHT_ALLOWED_PREFIXES", "")))
        ),
    )
