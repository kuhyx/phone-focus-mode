"""Walk RethinkDNS's screens to the universal domain rules and add entries.

Resource-ids are the contract with the app; labels are not, because the UI is
in the phone's locale (Polish here). The one place a label is unavoidable --
the two tabs of the rules screen -- is resolved by position instead.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from rethink_rules.rules import DomainRule, RuleKind
from rethink_rules.uia import Device, Node, UiError, find

RETHINK_PACKAGE = "com.celzero.bravedns"
HOME_ACTIVITY = f"{RETHINK_PACKAGE}/.ui.activity.LauncherAliasAppLock"
RULES_ACTIVITY = f"{RETHINK_PACKAGE}/{RETHINK_PACKAGE}.ui.activity.CustomRulesActivity"

# Home -> Firewall card -> "IP & port rules" row -> second tab (domain rules).
ID_HOME_FIREWALL = "fhs_card_firewall_ll"
ID_UNIVERSAL_RULES = "custom_ip_domain_universal_rl"
ID_TAB_LAYOUT = "logs_act_tabLayout"
DOMAIN_TAB_INDEX = 1

# The domain-rules tab.
ID_ADD_FAB = "cda_add_fab"
ID_SEARCH = "search_src_text"
# The search view's own "x". NOT cda_search_delete_icon, which sits right next
# to it and opens "Delete all Domain Rules?" -- found the hard way, 2026-09-18.
ID_SEARCH_CLEAR = "search_close_btn"
ID_RULE_LABEL = "custom_domain_label_tv"
ID_RULE_STATUS_ICON = "custom_domain_status_icon"
BLOCKED_STATUS_GLYPH = "B"

# The add-rule dialog.
ID_CHIP_DOMAIN = "dacd_domain_chip"
ID_CHIP_WILDCARD = "dacd_wildcard_chip"
ID_EDIT = "dacd_domain_edit_text"
ID_BLOCK = "dacd_block_btn"
# Labelled "Ok": closes the dialog, which stays open after a successful add so
# several rules can be entered in a row (toast: "Domena dodana pomyslnie").
ID_DIALOG_CLOSE = "dacd_cancel_btn"

_CHIP_FOR_KIND = {RuleKind.DOMAIN: ID_CHIP_DOMAIN, RuleKind.WILDCARD: ID_CHIP_WILDCARD}

Log = Callable[[str], None]


@dataclass
class ApplyReport:
    """What happened to each requested rule."""

    added: list[DomainRule] = field(default_factory=list)
    already_present: list[DomainRule] = field(default_factory=list)
    failed: list[tuple[DomainRule, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when every rule is now on the device."""
        return not self.failed


def _domain_tab(nodes: list[Node]) -> Node:
    layout = find(nodes, short_id=ID_TAB_LAYOUT)
    if layout is None:
        msg = "rules screen has no tab layout"
        raise UiError(msg)
    tabs = [n for n in nodes if n.text and n.inside(layout)]
    if len(tabs) <= DOMAIN_TAB_INDEX:
        msg = f"rules screen shows {len(tabs)} tab(s), expected at least {DOMAIN_TAB_INDEX + 1}"
        raise UiError(msg)
    return tabs[DOMAIN_TAB_INDEX]


def open_domain_rules(dev: Device) -> None:
    """From anywhere, land on the universal domain-rules tab."""
    dev.start_activity(HOME_ACTIVITY)
    dev.tap_id(ID_HOME_FIREWALL)
    dev.tap_id(ID_UNIVERSAL_RULES)
    dev.tap(_domain_tab(dev.dump()))
    if find(dev.dump(), short_id=ID_ADD_FAB) is None:
        msg = "domain-rules tab did not show its add button"
        raise UiError(msg)


def _on_rules_screen(dev: Device) -> bool:
    return (
        dev.focused_window() == RULES_ACTIVITY
        and find(dev.dump(), short_id=ID_ADD_FAB) is not None
    )


def _clear_search(dev: Device, nodes: list[Node] | None = None) -> None:
    """Empty the search box if it holds anything (the "x" only exists then)."""
    clear = find(nodes if nodes is not None else dev.dump(), short_id=ID_SEARCH_CLEAR)
    if clear is not None:
        dev.tap(clear)


def is_blocked(dev: Device, rule: DomainRule) -> bool:
    """Search the list for ``rule`` and read its status glyph."""
    _clear_search(dev)
    dev.tap_id(ID_SEARCH)
    dev.type_text(rule.text)
    nodes = dev.dump()
    blocked = False
    for label in (
        n for n in nodes if n.short_id == ID_RULE_LABEL and n.text == rule.text
    ):
        # The status icon is the next status node after this label in document order.
        after = nodes[nodes.index(label) :]
        icon = find(after, short_id=ID_RULE_STATUS_ICON)
        blocked = icon is not None and icon.text == BLOCKED_STATUS_GLYPH
        break
    _clear_search(dev, nodes)
    return blocked


def add_rule(dev: Device, rule: DomainRule) -> None:
    """Add ``rule`` through the dialog and close it. Success is judged by the read-back."""
    dev.tap_id(ID_ADD_FAB)
    dev.tap_id(_CHIP_FOR_KIND[rule.kind])
    dev.tap_id(ID_EDIT)
    dev.type_text(rule.text)
    dev.tap_id(ID_BLOCK)
    close = find(dev.dump(), short_id=ID_DIALOG_CLOSE)
    if close is not None:
        dev.tap(close)


def _ensure_rules_screen(dev: Device, log: Log) -> None:
    """Re-navigate if the app wandered off (seen: it dropped to the launcher)."""
    if not _on_rules_screen(dev):
        log("  (rules screen lost; re-opening)")
        open_domain_rules(dev)


def apply_rules(dev: Device, rules: list[DomainRule], log: Log = print) -> ApplyReport:
    """Add every rule that is not already blocked, and read each one back."""
    report = ApplyReport()
    open_domain_rules(dev)
    for rule in rules:
        try:
            _ensure_rules_screen(dev, log)
            if is_blocked(dev, rule):
                report.already_present.append(rule)
                log(f"  = {rule.text} (already blocked)")
                continue
            add_rule(dev, rule)
            _ensure_rules_screen(dev, log)
            if not is_blocked(dev, rule):
                report.failed.append((rule, "not found in the list after adding"))
                log(f"  ! {rule.text} not listed after adding")
                continue
            report.added.append(rule)
            log(f"  + {rule.text}")
        except UiError as error:
            report.failed.append((rule, str(error)))
            log(f"  ! {rule.text}: {error}")
    return report
