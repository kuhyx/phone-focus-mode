"""A thin adb + uiautomator driver: dump the hierarchy, find by id, tap.

Coordinates are never remembered between actions. Each tap re-dumps the
hierarchy and resolves the target's bounds from that dump, so a dialog that
shifted for the keyboard, or a screen that changed underneath us, produces a
"not found" error instead of a tap on whatever now sits at the old spot.
"""

from __future__ import annotations

import re
import shlex
import subprocess
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass

Runner = Callable[[Sequence[str]], str]
Sleeper = Callable[[float], None]

_NODE = re.compile(r"<node ([^>]*?)/?>")
_ATTR = re.compile(r'(\S+?)="([^"]*)"')
_BOUNDS = re.compile(r"\d+")
_BOUNDS_FIELDS = 4
_SETTLE_SECONDS = 1.2
_DEFAULT_TRIES = 3
_UI_DUMP_PATH = "/sdcard/rethink_rules_ui.xml"


class UiError(RuntimeError):
    """The screen did not hold what the driver expected."""


@dataclass(frozen=True)
class Node:
    """One element of a uiautomator dump."""

    resource_id: str
    text: str
    bounds: tuple[int, int, int, int]

    @property
    def short_id(self) -> str:
        """The resource-id without its package prefix."""
        return self.resource_id.rsplit("/", 1)[-1]

    @property
    def center(self) -> tuple[int, int]:
        """Tap target."""
        x1, y1, x2, y2 = self.bounds
        return (x1 + x2) // 2, (y1 + y2) // 2

    def inside(self, other: Node) -> bool:
        """Whether this node's box lies within ``other``'s."""
        x1, y1, x2, y2 = self.bounds
        ox1, oy1, ox2, oy2 = other.bounds
        return x1 >= ox1 and y1 >= oy1 and x2 <= ox2 and y2 <= oy2


def parse_nodes(xml: str) -> list[Node]:
    """Flatten a uiautomator dump into nodes, document order."""
    nodes: list[Node] = []
    for match in _NODE.finditer(xml):
        attrs = dict(_ATTR.findall(match.group(1)))
        numbers = [int(n) for n in _BOUNDS.findall(attrs.get("bounds", ""))]
        if len(numbers) != _BOUNDS_FIELDS:
            continue
        x1, y1, x2, y2 = numbers
        nodes.append(
            Node(attrs.get("resource-id", ""), attrs.get("text", ""), (x1, y1, x2, y2))
        )
    return nodes


def find(nodes: Sequence[Node], *, short_id: str = "", text: str = "") -> Node | None:
    """First node matching the short resource-id, or the exact text."""
    for node in nodes:
        if short_id and node.short_id == short_id:
            return node
        if text and node.text == text:
            return node
    return None


def default_runner(args: Sequence[str]) -> str:
    """Run adb and return stdout; a non-zero exit is an error."""
    completed = subprocess.run(
        ["adb", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        msg = f"adb {' '.join(args)} failed: {completed.stderr.strip()}"
        raise UiError(msg)
    return completed.stdout


class Device:
    """The phone, through adb."""

    def __init__(
        self,
        run: Runner = default_runner,
        *,
        serial: str | None = None,
        sleep: Sleeper = time.sleep,
    ) -> None:
        self._run = run
        self._serial = serial
        self._sleep = sleep

    def _adb(self, *args: str) -> str:
        prefix = ["-s", self._serial] if self._serial else []
        return self._run([*prefix, *args])

    def shell(self, command: str) -> str:
        """Run one shell command on the device."""
        return self._adb("shell", command)

    def settle(self, seconds: float = _SETTLE_SECONDS) -> None:
        """Give the UI time to redraw."""
        self._sleep(seconds)

    def dump(self) -> list[Node]:
        """A fresh hierarchy."""
        self.shell(f"uiautomator dump {_UI_DUMP_PATH} >/dev/null")
        return parse_nodes(self.shell(f"cat {_UI_DUMP_PATH}"))

    def focused_window(self) -> str:
        """The window that has focus, e.g. ``com.celzero.bravedns/...``."""
        out = self.shell("dumpsys window | grep mCurrentFocus")
        match = re.search(r"u0 (\S+?)\}", out)
        return match.group(1) if match else ""

    def tap(self, node: Node) -> None:
        """Tap the centre of ``node`` and wait for the UI to settle."""
        x, y = node.center
        self.shell(f"input tap {x} {y}")
        self.settle()

    def tap_id(self, short_id: str, *, tries: int = _DEFAULT_TRIES) -> Node:
        """Re-dump and tap ``short_id``; retry while the screen is still changing."""
        for attempt in range(tries):
            node = find(self.dump(), short_id=short_id)
            if node is not None:
                self.tap(node)
                return node
            if attempt < tries - 1:
                self.settle()
        msg = f"no element with resource-id {short_id!r} on screen"
        raise UiError(msg)

    def type_text(self, text: str) -> None:
        """Type into the focused field. Quoted so ``*`` reaches the app intact."""
        self.shell(f"input text {shlex.quote(text)}")
        self.settle()

    def back(self) -> None:
        """Press Back."""
        self.shell("input keyevent BACK")
        self.settle()

    def start_activity(self, component: str) -> None:
        """Launch (or bring forward) ``package/.Activity``."""
        self.shell(f"am start -n {component} >/dev/null")
        self.settle(2.0)
