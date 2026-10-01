"""The workday-lockdown allowlist: parsed, validated and exported.

wake-alarm's missed-workday lockdown applies its own exact-match list, narrower
than the night list. Two failure modes matter more than the happy path: a list
naming an app the day list does not know (it would widen the policy), and an
unconfigured list exported as ``[]`` (it would hide the dialer). Both are
pinned here.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from focus_policy.export import ENFORCER_PACKAGE, policy_to_dict
from focus_policy.geometry import HomeLocation
from focus_policy.loader import load_policy
from focus_policy.model import FocusPolicy, PolicyError

REPO_ROOT = Path(__file__).resolve().parents[2]

_HOME = HomeLocation(latitude=52.0, longitude=21.0, radius_m=150.0, hysteresis_m=30.0)
_DAY = frozenset({"com.launcher", "org.dialer", "com.maps", "com.game"})


def _policy(lockdown: frozenset[str] | None) -> FocusPolicy:
    return FocusPolicy(
        home=_HOME,
        allowed_packages=_DAY,
        night_allowed_packages=frozenset({"com.launcher", "org.dialer"}),
        never_disable_prefixes=("com.android.settings",),
        launcher_package="com.launcher",
        lockdown_allowed_packages=lockdown,
    )


def test_lockdown_list_outside_day_list_is_rejected() -> None:
    with pytest.raises(PolicyError, match="lockdown_allowed_packages must be a subset"):
        _policy(frozenset({"org.dialer", "com.unknown"}))


def test_lockdown_list_may_hold_day_only_apps() -> None:
    """Maps is day-only; a lockdown spent away from home still needs it."""
    policy = _policy(frozenset({"org.dialer", "com.maps"}))
    assert policy.lockdown_allowed_packages == {"org.dialer", "com.maps"}


def test_export_adds_enforcer_to_configured_list() -> None:
    exported = policy_to_dict(_policy(frozenset({"org.dialer"})))
    assert exported["lockdown_allowed_packages"] == sorted(
        {"org.dialer", ENFORCER_PACKAGE},
    )


def test_unconfigured_list_is_omitted_not_exported_empty() -> None:
    """Absent lets the enforcer fall back to the night list; [] would not."""
    assert "lockdown_allowed_packages" not in policy_to_dict(_policy(None))


def _write_config(tmp_path: Path, extra: str) -> Path:
    config = tmp_path / "config.sh"
    config.write_text(
        "export HOME_LAT=52.0\nexport HOME_LON=21.0\n"
        "export LAUNCHER_PACKAGE=com.launcher\n"
        'export WHITELIST="\ncom.launcher\norg.dialer\ncom.game\n"\n'
        'export NIGHT_WHITELIST="\ncom.launcher\n"\n' + extra,
        encoding="utf-8",
    )
    return config


def test_loader_reads_lockdown_whitelist(tmp_path: Path) -> None:
    config = _write_config(
        tmp_path,
        'export LOCKDOWN_WHITELIST="\n# calls\norg.dialer\n"\n',
    )
    assert load_policy(config).lockdown_allowed_packages == {"org.dialer"}


def test_loader_without_lockdown_whitelist_is_unconfigured(tmp_path: Path) -> None:
    assert load_policy(_write_config(tmp_path, "")).lockdown_allowed_packages is None


def test_real_config_lockdown_list_excludes_distractions(tmp_path: Path) -> None:
    """The shipped list keeps the essentials and drops the distractions."""
    secrets = tmp_path / "config_secrets.sh"
    secrets.write_text("export HOME_LAT=52.0\nexport HOME_LON=21.0\n", encoding="utf-8")
    policy = load_policy(REPO_ROOT / "config.sh", secrets)
    lockdown = policy.lockdown_allowed_packages
    assert lockdown is not None
    for essential in (
        "org.fossify.phone",
        "org.fossify.messages",
        "org.thoughtcrime.securesms",
        "com.google.android.apps.maps",
        "pl.mbank",
        "com.kuhy.wake_alarm_sync",
        "dev.kuhy.todo",
        # Obligations, not distractions: workout export + work-hours tracking.
        "org.runnerup",
        "com.kuhy.punchme",
    ):
        assert essential in lockdown
    # Night-list members the lockdown deliberately drops.
    for dropped in ("com.metrolist.music", "com.kuhy.punchme.sandbox"):
        assert dropped not in lockdown
    assert lockdown <= policy.allowed_packages
