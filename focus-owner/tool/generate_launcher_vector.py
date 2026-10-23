#!/usr/bin/env python3
"""Regenerate focus_owner's adaptive launcher icon as Android vector drawables.

Why this exists rather than a call to ``python_pkg.app_icons`` directly: the
shared generator's Android path runs ``flutter_launcher_icons``, which emits
PNG mipmaps. This repo blocks binaries at commit time, and the usual
binary-files escape hatch (symlink the artefact into a sibling directory) is
not available either -- CI builds the Android resources, and a dangling
symlink in a fresh clone reproduces exactly the AAPT "resource
mipmap/ic_launcher not found" failure the icon was added to fix.

So focus_owner takes the vector route: the SAME registry entry and the SAME
glyph fragment as every other app in the family, translated into
``<vector>`` drawables that live in the repo as text.

This is a translation, not a second source of truth. The glyph geometry,
accent, field colour and ink-circle placement all come from
``python_pkg.app_icons``; nothing here is hand-drawn. Re-run it after any
change to the glyph or to ``style.py``:

    python3 focus-owner/tool/generate_launcher_vector.py

Requires ~/src/testsAndMisc on the path (the shared generator is not installed as
a package). Verified by ``flutter build apk --release``: if the conversion
emits malformed pathData, AAPT fails the build rather than shipping a blank
icon.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RES = REPO_ROOT / "android" / "app" / "src" / "main" / "res"
TESTS_AND_MISC = Path.home() / "src/testsAndMisc"

if str(TESTS_AND_MISC) not in sys.path:
    sys.path.insert(0, str(TESTS_AND_MISC))

from python_pkg.app_icons import fit, style
from python_pkg.app_icons.apps import APPS
from python_pkg.app_icons.glyphs import get_glyph

APP = APPS["focus_owner"]

# Android adaptive icons are authored on a 108x108dp canvas.
VIEWPORT = 108.0

# Every icon in the family fills the same circle: fit.placement centres the
# glyph on the 1024px master canvas and scales it so its furthest inked pixel,
# stroke included, sits style.INK_RADIUS from the centre. The PNG path
# (flutter_launcher_icons) then maps that canvas onto style.ADAPTIVE_CANVAS_DP
# of the adaptive canvas (its default 16% foreground inset), so the ink lands
# at style.INK_RADIUS_DP. This vector uses the very same mapping, which is what
# keeps focus_owner the size of its PNG-built siblings on the home screen.
# (It used to scale the glyph out to the 36dp mask edge, which made the padlock
# visibly bigger than every other icon.)
_PLACEMENT = fit.placement(get_glyph(APP.glyph), APP.accent)
DP_PER_PX = style.ADAPTIVE_CANVAS_DP / style.CANVAS
# render.build_svg divides the group stroke by the placement scale, so on the
# master canvas every stroke stays style.STROKE_WIDTH whatever the glyph scale.
STROKE_DP = style.STROKE_WIDTH * DP_PER_PX


def _map(x: float, y: float) -> tuple[float, float]:
    """Map a glyph-fragment point through the placement onto the dp viewport."""
    cx = _PLACEMENT.scale * x + _PLACEMENT.dx
    cy = _PLACEMENT.scale * y + _PLACEMENT.dy
    return (
        (cx - style.CENTRE) * DP_PER_PX + VIEWPORT / 2,
        (cy - style.CENTRE) * DP_PER_PX + VIEWPORT / 2,
    )


_NUM = re.compile(r"-?\d+(?:\.\d+)?")


def _scale_path(data: str) -> str:
    """Map one SVG path's coordinates from the 1024 canvas onto the viewport.

    Every command used by the family's glyphs (M, L, A, Z) takes coordinates
    that scale uniformly, EXCEPT the arc command's three middle parameters
    (x-axis-rotation and the two flags), which must pass through untouched.
    Scaling a flag would silently invert an arc's sweep.
    """
    out: list[str] = []
    for token in data.replace(",", " ").split():
        if token.isalpha():
            out.append(token)
            continue
        out.append(token)

    result: list[str] = []
    i = 0
    while i < len(out):
        tok = out[i]
        if tok in {"M", "L"}:
            x, y = _map(float(out[i + 1]), float(out[i + 2]))
            result.append(f"{tok}{x:.3f},{y:.3f}")
            i += 3
        elif tok == "A":
            rx = float(out[i + 1]) * _PLACEMENT.scale * DP_PER_PX
            ry = float(out[i + 2]) * _PLACEMENT.scale * DP_PER_PX
            rot, large, sweep = out[i + 3], out[i + 4], out[i + 5]
            x, y = _map(float(out[i + 6]), float(out[i + 7]))
            result.append(f"A{rx:.3f},{ry:.3f} {rot} {large},{sweep} {x:.3f},{y:.3f}")
            i += 8
        elif tok.upper() == "Z":
            result.append("Z")
            i += 1
        else:  # pragma: no cover - defensive; the family uses only M/L/A/Z
            msg = f"unhandled path command {tok!r} in glyph {APP.glyph!r}"
            raise ValueError(msg)
    return " ".join(result)


def _paths(colour: str) -> list[tuple[str, str, str | None]]:
    """Return (pathData, fillColor, strokeColor) for each path in the glyph.

    The stroked shackle becomes a stroked ``<path>``; the filled body keeps
    its evenodd fill so the keyhole stays punched out.
    """
    glyph = get_glyph(APP.glyph)
    body = glyph.body.replace(style.ACCENT_MARKER, colour)

    out: list[tuple[str, str, str | None]] = []
    for match in re.finditer(r"<path([^>]*)/>", body):
        attrs = match.group(1)
        data_match = re.search(r'd="([^"]+)"', attrs)
        if data_match is None:  # pragma: no cover - every path has a d
            continue
        scaled = _scale_path(data_match.group(1).replace("\\\n", " "))
        if 'stroke="none"' in attrs:
            out.append((scaled, colour, None))
        else:
            out.append((scaled, "@null", colour))
    return out


def _vector(colour: str, *, note: str) -> str:
    """Render one complete ``<vector>`` drawable."""
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!--",
        "  GENERATED by tool/generate_launcher_vector.py - do not edit by hand.",
        f"  {note}",
        "",
        f"  Glyph {APP.glyph!r} and accent {APP.accent} come from the shared icon",
        "  family in ~/src/testsAndMisc/python_pkg/app_icons; this file is a",
        "  translation of that SVG into an Android vector drawable, taken",
        "  because this repo blocks binary mipmaps at commit time.",
        "-->",
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="108dp"',
        '    android:height="108dp"',
        f'    android:viewportWidth="{VIEWPORT:g}"',
        f'    android:viewportHeight="{VIEWPORT:g}">',
    ]
    for data, fill, stroke in _paths(colour):
        lines.append("    <path")
        if stroke is None:
            lines.append(f'        android:fillColor="{fill}"')
            lines.append('        android:fillType="evenOdd"')
        else:
            lines.append(f'        android:strokeColor="{stroke}"')
            lines.append(f'        android:strokeWidth="{STROKE_DP:.3f}"')
            lines.append('        android:strokeLineCap="round"')
            lines.append('        android:strokeLineJoin="round"')
        lines.append(f'        android:pathData="{data}" />')
    lines.append("</vector>")
    return "\n".join(lines) + "\n"


def main() -> None:
    """Write the foreground, monochrome and colour resources."""
    (RES / "drawable").mkdir(parents=True, exist_ok=True)
    (RES / "values").mkdir(parents=True, exist_ok=True)

    (RES / "drawable" / "ic_launcher_foreground.xml").write_text(
        _vector(APP.accent, note="Adaptive-icon foreground layer."),
        encoding="utf-8",
    )
    (RES / "drawable" / "ic_launcher_monochrome.xml").write_text(
        _vector(
            style.MONOCHROME,
            note="Android 13 themed layer; the system recolours flat white.",
        ),
        encoding="utf-8",
    )
    (RES / "values" / "ic_launcher_colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!--\n"
        "  GENERATED by tool/generate_launcher_vector.py - do not edit by hand.\n"
        f"  Charcoal field from the shared family (style.BACKGROUND).\n"
        "-->\n"
        "<resources>\n"
        f'    <color name="ic_launcher_background">{style.BACKGROUND}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    print(f"wrote foreground, monochrome and background for {APP.key}")


if __name__ == "__main__":
    main()
