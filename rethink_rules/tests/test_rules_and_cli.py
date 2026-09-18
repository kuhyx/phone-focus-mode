"""Rule expansion, the config reader, the uia primitives and the CLI."""

from __future__ import annotations

from pathlib import Path

import pytest

from rethink_rules.__main__ import EXIT_CONFIG, EXIT_FAILED_RULES, EXIT_OK, main
from rethink_rules.rules import (
    DomainRule,
    RuleKind,
    RulesConfigError,
    load_rules,
    rules_from_lists,
)
from rethink_rules.tests.fake_phone import FakePhone
from rethink_rules.uia import Device, UiError, default_runner, find, parse_nodes

CONFIG = """
export RETHINK_BLOCK_DOMAINS="
# comment line
pyszne.pl
wolt.com
"
export RETHINK_BLOCK_EXACT_HOSTS="
www.facebook.com
"
"""


def test_each_domain_becomes_an_exact_and_a_wildcard_rule() -> None:
    rules = rules_from_lists(frozenset({"pyszne.pl"}), frozenset({"www.facebook.com"}))

    assert rules == [
        DomainRule(RuleKind.DOMAIN, "pyszne.pl"),
        DomainRule(RuleKind.WILDCARD, "*.pyszne.pl"),
        DomainRule(RuleKind.DOMAIN, "www.facebook.com"),
    ]


def test_rules_are_sorted_so_runs_are_reproducible() -> None:
    rules = rules_from_lists(frozenset({"wolt.com", "bolt.eu"}), frozenset())

    assert [r.text for r in rules] == ["bolt.eu", "*.bolt.eu", "wolt.com", "*.wolt.com"]


@pytest.mark.parametrize("bad", ["not a domain", "*.already.wild", "nodots", "-x.com"])
def test_an_entry_that_is_not_a_domain_is_rejected(bad: str) -> None:
    with pytest.raises(RulesConfigError, match="RETHINK_BLOCK_DOMAINS"):
        rules_from_lists(frozenset({bad}), frozenset())


def test_exact_hosts_are_validated_under_their_own_name() -> None:
    with pytest.raises(RulesConfigError, match="RETHINK_BLOCK_EXACT_HOSTS"):
        rules_from_lists(frozenset(), frozenset({"bad host"}))


def test_load_rules_reads_both_lists_and_skips_comments(tmp_path: Path) -> None:
    config = tmp_path / "config_rethink.sh"
    config.write_text(CONFIG, encoding="utf-8")

    assert [r.text for r in load_rules(config)] == [
        "pyszne.pl",
        "*.pyszne.pl",
        "wolt.com",
        "*.wolt.com",
        "www.facebook.com",
    ]


def test_load_rules_refuses_a_config_with_neither_list(tmp_path: Path) -> None:
    config = tmp_path / "empty.sh"
    config.write_text("export OTHER=1\n", encoding="utf-8")
    with pytest.raises(RulesConfigError, match="neither"):
        load_rules(config)


# -- uia -------------------------------------------------------------------


def test_parse_nodes_reads_ids_text_and_bounds_and_skips_boundless_nodes() -> None:
    xml = (
        '<hierarchy><node resource-id="a:id/x" text="hi" bounds="[0,0][10,20]"/>'
        '<node resource-id="" text="" bounds="" /></hierarchy>'
    )
    nodes = parse_nodes(xml)

    assert len(nodes) == 1
    assert nodes[0].short_id == "x"
    assert nodes[0].center == (5, 10)


def test_find_matches_by_short_id_or_exact_text() -> None:
    nodes = parse_nodes(
        '<node resource-id="p:id/one" text="One" bounds="[0,0][1,1]"/>'
        '<node resource-id="p:id/two" text="Two" bounds="[0,0][1,1]"/>'
    )

    assert find(nodes, short_id="two") is nodes[1]
    assert find(nodes, text="One") is nodes[0]
    assert find(nodes, text="Three") is None


def test_tap_id_retries_then_raises_with_the_id_in_the_message() -> None:
    phone = FakePhone(screen="rules")
    naps: list[float] = []
    dev = Device(phone, sleep=naps.append)

    with pytest.raises(UiError, match="no_such_id"):
        dev.tap_id("no_such_id", tries=2)
    assert naps  # it waited between attempts rather than failing instantly


def test_serial_is_passed_to_every_adb_call() -> None:
    seen: list[list[str]] = []

    def runner(args: list[str]) -> str:
        seen.append(list(args))
        return ""

    Device(runner, serial="XYZ", sleep=lambda _s: None).back()

    assert seen == [["-s", "XYZ", "shell", "input keyevent BACK"]]


def test_type_text_quotes_so_a_star_survives_the_device_shell() -> None:
    seen: list[str] = []
    Device(lambda a: seen.append(a[-1]) or "", sleep=lambda _s: None).type_text(
        "*.x.pl"
    )

    assert seen == ["input text '*.x.pl'"]


def test_focused_window_is_empty_when_nothing_matches() -> None:
    dev = Device(lambda _a: "garbage", sleep=lambda _s: None)

    assert dev.focused_window() == ""


def test_default_runner_raises_on_adb_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    class Completed:
        returncode = 1
        stdout = ""
        stderr = "device offline"

    monkeypatch.setattr(
        "rethink_rules.uia.subprocess.run", lambda *_a, **_k: Completed()
    )
    with pytest.raises(UiError, match="device offline"):
        default_runner(["shell", "true"])


def test_default_runner_returns_stdout(monkeypatch: pytest.MonkeyPatch) -> None:
    class Completed:
        returncode = 0
        stdout = "ok\n"
        stderr = ""

    monkeypatch.setattr(
        "rethink_rules.uia.subprocess.run", lambda *_a, **_k: Completed()
    )

    assert default_runner(["shell", "true"]) == "ok\n"


# -- CLI -------------------------------------------------------------------


def _config(tmp_path: Path) -> Path:
    config = tmp_path / "config_rethink.sh"
    config.write_text(CONFIG, encoding="utf-8")
    return config


def test_dry_run_lists_rules_and_touches_no_device(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = main(["--config", str(_config(tmp_path)), "--dry-run"])

    out = capsys.readouterr().out
    assert code == EXIT_OK
    assert "5 rule(s)" in out
    assert "wildcard *.pyszne.pl" in out


def test_config_errors_exit_2(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = main(["--config", str(tmp_path / "missing.sh"), "--dry-run"])

    assert code == EXIT_CONFIG
    assert "error:" in capsys.readouterr().err


def test_a_full_run_reports_counts_and_exits_0(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    phone = FakePhone(rules={"wolt.com": "B"})
    dev = Device(phone, sleep=lambda _s: None)

    code = main(["--config", str(_config(tmp_path))], device=dev)

    assert code == EXIT_OK
    assert "added 4, already present 1, failed 0" in capsys.readouterr().out


def test_a_run_with_a_failed_rule_exits_1(tmp_path: Path) -> None:
    phone = FakePhone(reject_texts={"www.facebook.com"})
    dev = Device(phone, sleep=lambda _s: None)

    assert main(["--config", str(_config(tmp_path))], device=dev) == EXIT_FAILED_RULES


def test_a_navigation_failure_exits_1(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    dev = Device(lambda _a: "", sleep=lambda _s: None)  # a phone that shows nothing

    assert main(["--config", str(_config(tmp_path))], device=dev) == EXIT_FAILED_RULES
    assert "fhs_card_firewall_ll" in capsys.readouterr().err


def test_module_entry_point_runs_main(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import runpy
    import sys

    monkeypatch.setattr(
        sys, "argv", ["rethink_rules", "--config", str(_config(tmp_path)), "--dry-run"]
    )
    entry = Path(__file__).resolve().parents[1] / "__main__.py"
    with pytest.raises(SystemExit) as exit_info:
        runpy.run_path(str(entry), run_name="__main__")
    assert exit_info.value.code == EXIT_OK
