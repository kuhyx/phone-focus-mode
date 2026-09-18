"""Driver tests against the scripted phone in fake_phone.py."""

from __future__ import annotations

import pytest

from rethink_rules.driver import add_rule, apply_rules, is_blocked, open_domain_rules
from rethink_rules.rules import DomainRule, RuleKind
from rethink_rules.tests.fake_phone import FakePhone
from rethink_rules.uia import Device, Node, UiError


def _device(phone: FakePhone) -> Device:
    return Device(phone, serial="SERIAL", sleep=lambda _s: None)


def _rules(*texts: str) -> list[DomainRule]:
    return [
        DomainRule(RuleKind.WILDCARD if t.startswith("*.") else RuleKind.DOMAIN, t)
        for t in texts
    ]


def test_apply_adds_every_rule_and_reads_it_back() -> None:
    phone = FakePhone()
    report = apply_rules(
        _device(phone), _rules("pyszne.pl", "*.pyszne.pl"), log=lambda _m: None
    )

    assert report.ok
    assert [r.text for r in report.added] == ["pyszne.pl", "*.pyszne.pl"]
    assert phone.rules == {"pyszne.pl": "B", "*.pyszne.pl": "B"}


def test_wildcard_rules_select_the_wildcard_chip() -> None:
    phone = FakePhone(screen="rules")
    add_rule(_device(phone), DomainRule(RuleKind.WILDCARD, "*.wolt.com"))

    assert phone.chip == "wildcard"
    assert "*.wolt.com" in phone.rules


def test_already_blocked_rules_are_skipped_not_re_added() -> None:
    phone = FakePhone(rules={"glovo.com": "B"})
    lines: list[str] = []
    report = apply_rules(_device(phone), _rules("glovo.com"), log=lines.append)

    assert report.ok
    assert [r.text for r in report.already_present] == ["glovo.com"]
    assert not report.added
    assert not any(
        c.startswith("input text 'glovo.com'") and "dacd" in c for c in phone.calls
    )
    assert any("already blocked" in line for line in lines)


def test_a_trusted_rule_counts_as_not_blocked() -> None:
    phone = FakePhone(rules={"uber.com": "T"}, screen="rules")

    assert not is_blocked(_device(phone), DomainRule(RuleKind.DOMAIN, "uber.com"))


def test_the_search_box_is_emptied_after_each_lookup() -> None:
    phone = FakePhone(rules={"bolt.eu": "B"}, screen="rules")
    is_blocked(_device(phone), DomainRule(RuleKind.DOMAIN, "bolt.eu"))

    assert phone.search == ""


def test_the_delete_all_icon_is_never_tapped() -> None:
    """It sits beside the search box and wipes every rule after one confirm."""
    phone = FakePhone(rules={"a.com": "B", "b.com": "B"})
    apply_rules(
        _device(phone), _rules("a.com", "c.com", "*.c.com"), log=lambda _m: None
    )

    assert phone.rules == {"a.com": "B", "b.com": "B", "c.com": "B", "*.c.com": "B"}


def test_a_rule_the_dialog_does_not_accept_is_reported_as_failed() -> None:
    phone = FakePhone(reject_texts={"bad..domain"})
    lines: list[str] = []
    report = apply_rules(
        _device(phone), _rules("bad..domain", "good.com"), log=lines.append
    )

    assert not report.ok
    assert [(r.text, why) for r, why in report.failed] == [
        ("bad..domain", "not found in the list after adding")
    ]
    assert [r.text for r in report.added] == ["good.com"]
    assert any(line.startswith("  ! bad..domain") for line in lines)


def test_losing_the_rules_screen_mid_run_re_navigates() -> None:
    """Seen on the real phone: the app dropped to the launcher after an add."""
    phone = FakePhone(drop_to_launcher_after_add=True)
    lines: list[str] = []
    report = apply_rules(_device(phone), _rules("x.com", "y.com"), log=lines.append)

    assert report.ok
    assert phone.rules == {"x.com": "B", "y.com": "B"}
    assert any("re-opening" in line for line in lines)


def test_open_domain_rules_fails_loudly_when_the_tab_layout_is_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    phone = FakePhone()
    original = phone._render

    def without_tabs() -> str:
        return original().replace("logs_act_tabLayout", "something_else")

    monkeypatch.setattr(phone, "_render", without_tabs)
    with pytest.raises(UiError, match="no tab layout"):
        open_domain_rules(_device(phone))


def test_open_domain_rules_fails_loudly_when_a_tab_is_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    phone = FakePhone()
    original = phone._render

    def one_tab() -> str:
        return original().replace('text="domain rules"', 'text=""')

    monkeypatch.setattr(phone, "_render", one_tab)
    with pytest.raises(UiError, match="1 tab"):
        open_domain_rules(_device(phone))


def test_open_domain_rules_fails_loudly_when_the_fab_never_appears(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    phone = FakePhone()
    original = phone._render

    def no_fab() -> str:
        return original().replace("cda_add_fab", "nothing_here")

    monkeypatch.setattr(phone, "_render", no_fab)
    with pytest.raises(UiError, match="add button"):
        open_domain_rules(_device(phone))


def test_a_ui_error_on_one_rule_does_not_stop_the_others(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    phone = FakePhone()
    dev = _device(phone)
    original_tap_id = dev.tap_id
    blown = {"done": False}

    def flaky_tap_id(short_id: str, *, tries: int = 3) -> Node:
        if short_id == "dacd_domain_edit_text" and not blown["done"]:
            blown["done"] = True
            phone.dialog_open = False
            msg = "simulated: dialog vanished"
            raise UiError(msg)
        return original_tap_id(short_id, tries=tries)

    monkeypatch.setattr(dev, "tap_id", flaky_tap_id)
    report = apply_rules(dev, _rules("first.com", "second.com"), log=lambda _m: None)

    assert [r.text for r, _ in report.failed] == ["first.com"]
    assert [r.text for r in report.added] == ["second.com"]
