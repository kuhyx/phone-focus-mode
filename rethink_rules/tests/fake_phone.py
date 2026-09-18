"""A scripted RethinkDNS: answers adb calls the way the real screens do.

The fake keeps a tiny state machine (home / firewall / rules screen /
dialog / search) and renders each state as the resource-ids the driver looks
for. It exists so the navigation logic, the read-back and every failure branch
run in CI without a phone. It also records every shell command, so a test can
assert that the delete-all icon was never touched.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass, field

PKG = "com.celzero.bravedns"
RULES_WINDOW = f"{PKG}/{PKG}.ui.activity.CustomRulesActivity"
HOME_WINDOW = f"{PKG}/{PKG}.ui.HomeScreenActivity"

# Fixed boxes; the driver only needs them to be non-degenerate and nested.
_TAB_LAYOUT = "[0,132][1080,258]"
_TAB_IP = "[149,166][480,223]"
_TAB_DOMAIN = "[641,166][914,223]"
_DELETE_ALL = "[948,290][1050,416]"


def _node(rid: str, text: str = "", bounds: str = "") -> tuple[str, str, str]:
    return rid, text, bounds


def _xml(entries: list[tuple[str, str, str]]) -> str:
    """Render entries; each one without explicit bounds gets its own row so
    that a tap resolves to exactly one node."""
    out = ['<?xml version="1.0"?><hierarchy>']
    row = 500
    for rid, text, bounds in entries:
        if not bounds:
            bounds = f"[10,{row}][100,{row + 90}]"
            row += 120
        full = f"{PKG}:id/{rid}" if rid else ""
        out.append(f'<node resource-id="{full}" text="{text}" bounds="{bounds}" />')
    out.append("</hierarchy>")
    return "".join(out)


@dataclass
class FakePhone:
    """State + renderer + adb runner in one."""

    rules: dict[str, str] = field(default_factory=dict)  # text -> "B" | "T"
    screen: str = "launcher"
    dialog_open: bool = False
    chip: str = "domain"
    typed: str = ""
    search: str = ""
    calls: list[str] = field(default_factory=list)
    reject_texts: set[str] = field(default_factory=set)
    drop_to_launcher_after_add: bool = False

    # -- rendering -----------------------------------------------------------
    def _render(self) -> str:
        parts: list[tuple[str, str, str]] = []
        if self.screen == "home":
            parts.append(_node("fhs_card_firewall_ll"))
        elif self.screen == "firewall":
            parts.append(_node("custom_ip_domain_universal_rl"))
        elif self.screen == "rules":
            parts.append(_node("logs_act_tabLayout", bounds=_TAB_LAYOUT))
            parts.append(_node("", "ip rules", _TAB_IP))
            parts.append(_node("", "domain rules", _TAB_DOMAIN))
            parts.append(_node("search_src_text", self.search or "Search"))
            if self.search:
                parts.append(_node("search_close_btn"))
            parts.append(_node("cda_search_delete_icon", bounds=_DELETE_ALL))
            for text, status in sorted(self.rules.items()):
                if self.search and self.search not in text:
                    continue
                parts.append(_node("custom_domain_label_tv", text))
                parts.append(_node("custom_domain_status_icon", status))
            parts.append(_node("cda_add_fab"))
            if self.dialog_open:
                parts.append(_node("dacd_domain_chip", "Domain"))
                parts.append(_node("dacd_wildcard_chip", "Wildcard"))
                parts.append(_node("dacd_domain_edit_text", self.typed))
                parts.append(_node("dacd_cancel_btn", "Ok"))
                parts.append(_node("dacd_block_btn", "block"))
        return _xml(parts)

    def _hit(self, x: int, y: int) -> str:
        """The smallest node under the point (a tab, not the layout around it)."""
        best, best_area = "", None
        for match in re.finditer(
            r'resource-id="(?:[^"]*/)?([^"]*)" text="([^"]*)" bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
            self._render(),
        ):
            rid, text, x1, y1, x2, y2 = match.groups()
            if not (int(x1) <= x <= int(x2) and int(y1) <= y <= int(y2)):
                continue
            area = (int(x2) - int(x1)) * (int(y2) - int(y1))
            if best_area is None or area < best_area:
                best, best_area = rid or text, area
        return best

    # -- behaviour -----------------------------------------------------------
    def _tap(self, target: str) -> None:
        if target == "fhs_card_firewall_ll":
            self.screen = "firewall"
        elif target == "custom_ip_domain_universal_rl":
            self.screen = "rules"
        elif target == "cda_add_fab":
            self.dialog_open, self.typed, self.chip = True, "", "domain"
        elif target == "dacd_domain_chip":
            self.chip = "domain"
        elif target == "dacd_wildcard_chip":
            self.chip = "wildcard"
        elif target == "dacd_block_btn":
            if self.typed and self.typed not in self.reject_texts:
                self.rules[self.typed] = "B"
            self.typed = ""
            if self.drop_to_launcher_after_add:
                self.screen, self.dialog_open = "launcher", False
        elif target == "dacd_cancel_btn":
            self.dialog_open = False
        elif target == "search_close_btn":
            self.search = ""
        elif target == "cda_search_delete_icon":
            msg = "the fake was asked to delete every rule"
            raise AssertionError(msg)

    def __call__(self, args: Sequence[str]) -> str:
        """The ``Runner`` protocol."""
        args = list(args)
        if args[:2] == ["-s", "SERIAL"]:
            args = args[2:]
        if args[0] != "shell":
            msg = f"unexpected adb args {args}"
            raise AssertionError(msg)
        command = args[1]
        self.calls.append(command)
        if command.startswith("uiautomator dump"):
            return ""
        if command.startswith("cat "):
            return self._render()
        if command.startswith("dumpsys window"):
            window = RULES_WINDOW if self.screen == "rules" else HOME_WINDOW
            return f"  mCurrentFocus=Window{{1 u0 {window}}}\n"
        if command.startswith("am start"):
            self.screen, self.dialog_open = "home", False
            return ""
        if command.startswith("input tap"):
            _, _, x, y = command.split()
            self._tap(self._hit(int(x), int(y)))
            return ""
        if command.startswith("input text"):
            text = command[len("input text ") :].strip("'")
            if self.dialog_open:
                self.typed += text
            else:
                self.search += text
            return ""
        if command.startswith("input keyevent BACK"):
            self.dialog_open = False
            return ""
        msg = f"unexpected shell command {command!r}"
        raise AssertionError(msg)
