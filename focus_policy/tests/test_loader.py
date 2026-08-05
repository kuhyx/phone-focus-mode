"""Tests for parsing policy out of the existing shell config."""

from __future__ import annotations

from datetime import time
from typing import TYPE_CHECKING

import pytest

from python_pkg.focus_policy.export import policy_to_dict, policy_to_json
from python_pkg.focus_policy.loader import (
    load_policy,
    parse_hhmm,
    parse_package_list,
    parse_shell_assignments,
)
from python_pkg.focus_policy.model import PolicyError

if TYPE_CHECKING:
    from pathlib import Path

MINIMAL_CONFIG = """
export RADIUS=150
export HYSTERESIS=30
export NIGHT_CURFEW_ENABLED=1
export NIGHT_CURFEW_START="2300"
export NIGHT_CURFEW_END="0500"
export LAUNCHER_PACKAGE="com.launcher"
export WHITELIST="
com.launcher
com.good
pl.mbank
"
export NIGHT_WHITELIST="
pl.mbank
"
export SYSTEM_NEVER_DISABLE="
com.android.settings
"
export WORKOUT_UNBLOCK_DOMAINS="
youtube.com
"
"""

SECRETS = "export HOME_LAT=52.2297\nexport HOME_LON=21.0122\n"


@pytest.fixture
def config_dir(tmp_path: Path) -> Path:
    """Write a minimal config plus secrets into a temporary directory."""
    (tmp_path / "config.sh").write_text(MINIMAL_CONFIG, encoding="utf-8")
    (tmp_path / "config_secrets.sh").write_text(SECRETS, encoding="utf-8")
    return tmp_path


class TestParseShellAssignments:
    """The narrow shell-assignment subset the loader understands."""

    @pytest.mark.parametrize(
        ("text", "expected"),
        [
            ('export A="x"', {"A": "x"}),
            ("export A='x'", {"A": "x"}),
            ("A=x", {"A": "x"}),
            ("readonly A=x", {"A": "x"}),
            ('export A="one\ntwo"', {"A": "one\ntwo"}),
        ],
    )
    def test_assignment_forms(self, text: str, expected: dict[str, str]) -> None:
        """Quoted, bare, exported, readonly, and multi-line forms all parse."""
        assert parse_shell_assignments(text) == expected

    def test_later_assignment_wins(self) -> None:
        """Re-assignment overwrites, matching shell semantics."""
        assert parse_shell_assignments("A=1\nA=2")["A"] == "2"

    def test_ignores_prose(self) -> None:
        """Comment prose without an assignment yields nothing."""
        assert parse_shell_assignments("# just a comment\n") == {}


class TestParsePackageList:
    """Whitespace-separated list blocks."""

    def test_drops_blanks_and_comments(self) -> None:
        """Only real entries survive."""
        assert parse_package_list("\ncom.a\n# note\n\n  com.b  \n") == frozenset(
            {"com.a", "com.b"},
        )

    def test_empty_string_is_empty_set(self) -> None:
        """An unset list is empty, not a set containing an empty string."""
        assert parse_package_list("") == frozenset()


class TestParseHhmm:
    """HHMM time parsing."""

    def test_parses_valid_time(self) -> None:
        """A well-formed HHMM string becomes a time."""
        assert parse_hhmm("2300", field_name="X") == time(23, 0)

    @pytest.mark.parametrize("value", ["230", "23000", "abcd", "2560", "2400"])
    def test_rejects_malformed_time(self, value: str) -> None:
        """Wrong length, non-digits, and impossible clock values all raise."""
        with pytest.raises(PolicyError, match="X"):
            parse_hhmm(value, field_name="X")


class TestLoadPolicy:
    """End-to-end policy loading."""

    def test_loads_expected_policy(self, config_dir: Path) -> None:
        """Every field is populated from the two files."""
        policy = load_policy(config_dir / "config.sh")
        assert policy.home.latitude == pytest.approx(52.2297)
        assert policy.home.radius_m == pytest.approx(150.0)
        assert policy.allowed_packages == frozenset(
            {"com.launcher", "com.good", "pl.mbank"},
        )
        assert policy.night_allowed_packages == frozenset({"pl.mbank"})
        assert policy.never_disable_prefixes == ("com.android.settings",)
        assert policy.workout_unblock_domains == frozenset({"youtube.com"})
        assert policy.curfew is not None
        assert policy.curfew.start == time(23, 0)
        assert policy.launcher_package == "com.launcher"

    def test_explicit_secrets_path_is_honoured(
        self,
        config_dir: Path,
        tmp_path: Path,
    ) -> None:
        """Secrets may live outside the config directory."""
        elsewhere = tmp_path / "other_secrets.sh"
        elsewhere.write_text("export HOME_LAT=1.0\nexport HOME_LON=2.0\n", "utf-8")
        policy = load_policy(config_dir / "config.sh", elsewhere)
        assert policy.home.latitude == pytest.approx(1.0)

    def test_rejects_placeholder_coordinates(self, config_dir: Path) -> None:
        """The shipped placeholder must fail loudly, never default to (0, 0).

        Silently treating an unset coordinate as the origin would place "home"
        in the Atlantic and disable the location gate entirely.
        """
        (config_dir / "config_secrets.sh").write_text(
            "export HOME_LAT=REDACTED_LAT\nexport HOME_LON=REDACTED_LON\n",
            encoding="utf-8",
        )
        with pytest.raises(PolicyError, match="placeholder"):
            load_policy(config_dir / "config.sh")

    def test_missing_secrets_file_reports_missing_setting(
        self,
        config_dir: Path,
    ) -> None:
        """With no secrets at all the error names the absent key."""
        (config_dir / "config_secrets.sh").unlink()
        with pytest.raises(PolicyError, match="HOME_LAT"):
            load_policy(config_dir / "config.sh")

    def test_missing_whitelist_is_fatal(self, tmp_path: Path) -> None:
        """A config without an allowlist cannot produce a usable policy."""
        (tmp_path / "config.sh").write_text("export RADIUS=150\n", encoding="utf-8")
        (tmp_path / "config_secrets.sh").write_text(SECRETS, encoding="utf-8")
        with pytest.raises(PolicyError, match="WHITELIST"):
            load_policy(tmp_path / "config.sh")

    def test_curfew_disabled_yields_no_window(self, config_dir: Path) -> None:
        """NIGHT_CURFEW_ENABLED=0 disables the window entirely."""
        text = MINIMAL_CONFIG.replace(
            "NIGHT_CURFEW_ENABLED=1",
            "NIGHT_CURFEW_ENABLED=0",
        )
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        assert load_policy(config_dir / "config.sh").curfew is None

    def test_defaults_apply_when_numbers_absent(self, config_dir: Path) -> None:
        """Radius and hysteresis fall back to the documented defaults."""
        text = MINIMAL_CONFIG.replace("export RADIUS=150\n", "").replace(
            "export HYSTERESIS=30\n",
            "",
        )
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        policy = load_policy(config_dir / "config.sh")
        assert policy.home.radius_m == pytest.approx(150.0)
        assert policy.home.hysteresis_m == pytest.approx(30.0)

    def test_blank_number_falls_back_to_default(self, config_dir: Path) -> None:
        """An empty value is treated as unset rather than as zero."""
        text = MINIMAL_CONFIG.replace("export RADIUS=150", 'export RADIUS=""')
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        assert load_policy(config_dir / "config.sh").home.radius_m == pytest.approx(
            150.0,
        )

    def test_non_numeric_radius_is_fatal(self, config_dir: Path) -> None:
        """A malformed number is an error, not a silent fallback."""
        text = MINIMAL_CONFIG.replace("export RADIUS=150", "export RADIUS=wide")
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        with pytest.raises(PolicyError, match="RADIUS"):
            load_policy(config_dir / "config.sh")

    def test_blank_launcher_becomes_none(self, config_dir: Path) -> None:
        """An empty launcher setting disables the launcher invariant."""
        text = MINIMAL_CONFIG.replace(
            'export LAUNCHER_PACKAGE="com.launcher"',
            'export LAUNCHER_PACKAGE=""',
        )
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        assert load_policy(config_dir / "config.sh").launcher_package is None


class TestExport:
    """Rendering the policy for the Kotlin backend."""

    def test_dict_round_trips_key_fields(self, config_dir: Path) -> None:
        """The exported document carries the policy the loader produced."""
        payload = policy_to_dict(load_policy(config_dir / "config.sh"))
        assert payload["schema_version"] == 1
        assert payload["curfew"] == {"start": "23:00", "end": "05:00"}
        assert payload["allowed_packages"] == ["com.good", "com.launcher", "pl.mbank"]
        assert payload["home"]["latitude"] == pytest.approx(52.2297)

    def test_absent_curfew_serialises_as_null(self, config_dir: Path) -> None:
        """No curfew renders as JSON null rather than being omitted."""
        text = MINIMAL_CONFIG.replace(
            "NIGHT_CURFEW_ENABLED=1",
            "NIGHT_CURFEW_ENABLED=0",
        )
        (config_dir / "config.sh").write_text(text, encoding="utf-8")
        assert policy_to_dict(load_policy(config_dir / "config.sh"))["curfew"] is None

    def test_redaction_hides_coordinates_only(self, config_dir: Path) -> None:
        """Redacted output keeps the radius but drops where the user lives."""
        policy = load_policy(config_dir / "config.sh")
        assert "52.2297" not in policy_to_json(policy, redact_home=True)
        assert "52.2297" in policy_to_json(policy)
        assert '"radius_m": 150.0' in policy_to_json(policy, redact_home=True)

    def test_json_is_stable(self, config_dir: Path) -> None:
        """Repeated renders are byte-identical, so diffs stay meaningful."""
        policy = load_policy(config_dir / "config.sh")
        assert policy_to_json(policy) == policy_to_json(policy)
