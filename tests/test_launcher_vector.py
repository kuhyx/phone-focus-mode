"""Geometry of focus_owner's generated launcher vector.

Every app in the shared icon family fills the same circle: the glyph's
furthest inked pixel, stroke included, sits ``style.INK_RADIUS`` (340px of
1024) from the centre, which on the adaptive-icon canvas is
``style.INK_RADIUS_DP`` from (54, 54). Before this was enforced the padlock
was scaled to reach 36dp and filled the whole launcher mask.

The emitted ``<vector>`` is converted back into an SVG and rasterised, so the
measurement is of the ink Android will actually draw, not of the path
coordinates (arcs and stroke caps reach past their endpoints).

The shared generator lives outside this repo (~/src/testsAndMisc) and needs
numpy, Pillow and rsvg-convert, none of which CI installs; the tests skip
there rather than fail.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from types import ModuleType

import pytest

_SHARED = Path.home() / "src/testsAndMisc/python_pkg/app_icons"
if not _SHARED.is_dir():
    pytest.skip("shared icon generator not checked out", allow_module_level=True)
if shutil.which("rsvg-convert") is None:
    pytest.skip("rsvg-convert not installed", allow_module_level=True)
np = pytest.importorskip("numpy")
Image = pytest.importorskip("PIL.Image")

_ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = _ROOT / "focus-owner" / "tool" / "generate_launcher_vector.py"
_RES = _ROOT / "focus-owner" / "android" / "app" / "src" / "main" / "res"
_A = "{http://schemas.android.com/apk/res/android}"
# Raster resolution for the measurement: 20px per dp keeps one pixel at
# 0.05dp, a fifth of the 1% (~0.24dp) tolerance.
_PX_PER_DP = 20
_TOLERANCE = 0.01


def _load_script() -> ModuleType:
    """Import the generator script, which is not part of any package."""
    spec = importlib.util.spec_from_file_location("generate_launcher_vector", _SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def gen() -> ModuleType:
    """The generator script, imported once for the module."""
    return _load_script()


@pytest.fixture(scope="module")
def style() -> ModuleType:
    """The shared family's style constants (no script import needed)."""
    root = str(_SHARED.parents[1])
    if root not in sys.path:
        sys.path.insert(0, root)
    return importlib.import_module("python_pkg.app_icons.style")


@pytest.fixture(scope="module", params=["committed", "generated"])
def foreground(request: pytest.FixtureRequest) -> ET.Element:
    """The foreground ``<vector>``: the checked-in drawable and the script's output."""
    if request.param == "committed":
        path = _RES / "drawable" / "ic_launcher_foreground.xml"
        return ET.fromstring(path.read_text(encoding="utf-8"))
    gen = request.getfixturevalue("gen")
    return ET.fromstring(gen._vector(gen.APP.accent, note="test"))


def _to_svg(vector: ET.Element) -> str:
    """Translate an Android ``<vector>`` back into an equivalent SVG."""
    width = vector.get(f"{_A}viewportWidth")
    height = vector.get(f"{_A}viewportHeight")
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">']
    for path in vector.iter("path"):
        fill = path.get(f"{_A}fillColor", "none")
        attrs = {
            "d": path.get(f"{_A}pathData"),
            "fill": "none" if fill == "@null" else fill,
            "fill-rule": "evenodd"
            if path.get(f"{_A}fillType") == "evenOdd"
            else "nonzero",
            "stroke": path.get(f"{_A}strokeColor", "none"),
            "stroke-width": path.get(f"{_A}strokeWidth", "0"),
            "stroke-linecap": path.get(f"{_A}strokeLineCap", "butt"),
            "stroke-linejoin": path.get(f"{_A}strokeLineJoin", "miter"),
        }
        parts.append("<path " + " ".join(f'{k}="{v}"' for k, v in attrs.items()) + "/>")
    parts.append("</svg>")
    return "\n".join(parts)


def _ink_radius_dp(vector: ET.Element, tmp_path: Path) -> float:
    """Return the furthest inked point's distance from the viewport centre, in dp."""
    viewport = float(vector.get(f"{_A}viewportWidth", "0"))
    assert viewport == 108, "adaptive icons are authored on a 108dp canvas"
    size = int(viewport * _PX_PER_DP)
    svg = tmp_path / "foreground.svg"
    png = tmp_path / "foreground.png"
    svg.write_text(_to_svg(vector), encoding="utf-8")
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(png), str(svg)],
        check=True,
    )
    with Image.open(png) as image:
        alpha = np.asarray(image.convert("RGBA"))[:, :, 3]
    ys, xs = np.nonzero(alpha > 127)
    assert xs.size, "foreground rendered no ink"
    centre = size / 2
    return float(np.hypot(xs + 0.5 - centre, ys + 0.5 - centre).max()) / _PX_PER_DP


def test_foreground_ink_sits_on_family_circle(
    style: ModuleType, foreground: ET.Element, tmp_path: Path
) -> None:
    """The padlock's furthest ink is INK_RADIUS_DP from (54, 54), within 1%."""
    want = style.INK_RADIUS_DP
    got = _ink_radius_dp(foreground, tmp_path)
    assert abs(got - want) <= want * _TOLERANCE, (
        f"ink radius {got:.3f}dp, want {want:.3f}dp"
    )


def test_stroke_keeps_family_weight(style: ModuleType, foreground: ET.Element) -> None:
    """Strokes are the family's 72px-on-1024 weight, mapped onto the dp canvas."""
    want = style.STROKE_WIDTH * style.ADAPTIVE_CANVAS_DP / style.CANVAS
    widths = [
        float(p.get(f"{_A}strokeWidth", "0"))
        for p in foreground.iter("path")
        if p.get(f"{_A}strokeWidth") is not None
    ]
    assert widths, "the padlock's shackle is stroked"
    for got in widths:
        assert abs(got - want) <= want * _TOLERANCE, (
            f"stroke {got:.3f}dp, want {want:.3f}dp"
        )


def test_committed_drawables_match_generator(gen: ModuleType) -> None:
    """The checked-in foreground and monochrome layers are the script's output."""
    style = gen.style
    pairs = {
        "ic_launcher_foreground.xml": gen._vector(
            gen.APP.accent, note="Adaptive-icon foreground layer."
        ),
        "ic_launcher_monochrome.xml": gen._vector(
            style.MONOCHROME,
            note="Android 13 themed layer; the system recolours flat white.",
        ),
    }
    for name, want in pairs.items():
        got = (_RES / "drawable" / name).read_text(encoding="utf-8")
        assert got == want, f"{name} is stale: rerun tool/generate_launcher_vector.py"
