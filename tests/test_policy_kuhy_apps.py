"""Gate: every app kuhy writes stays available, day and night --

with one deliberate, named exception.

`config.sh` allows `com.kuhy` and `dev.kuhy` as PREFIXES, so an app kuhy has
not written yet is allowed the moment it is installed. That guarantee is the
point of the prefix, and a comment cannot enforce it -- these tests can.

Four apps have already been bitten by the day-list-but-not-night-list version
of this bug. `dev.kuhy.todo`, `com.kuhy.punchme` and `com.kuhy.dufs_client`
each earned their own section in docs/DOCS-policy-lists.md after a build
shipped inside the curfew window was installed and then removed by the
enforcer; `com.kuhy.workout_app` was the fourth. One cause, met four times,
which is what the prefix replaces.

`com.kuhy.dufs_client` is now the ONE deliberate exception to the night half
of the guarantee: it is in `NIGHT_BLOCKED_PACKAGES`
(docs/DOCS-policy-lists.md#why-comkuhydufs_client-is-night-blocked), a policy
tier that wins over the `com.kuhy` night prefix for that one package without
touching the prefix itself. `test_every_kuhy_app_is_allowed_day_and_night`
below asserts the general guarantee for every kuhy app EXCEPT this one, and a
separate test pins the exception down explicitly so it cannot silently grow.

The trailing-dot assertion is the important one. Matching is on whole labels::

    package == prefix or package.startswith(prefix + ".")

so `com.kuhy.` matches NOTHING -- not even `com.kuhy.workout_app` -- and fails
silently while still reading as correct in review.
"""

from __future__ import annotations

import pathlib
import re

from focus_policy.loader import load_policy, read_config_text

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config.sh"

# The vendor namespaces kuhy ships under. Both must be allowed around the clock.
VENDOR_PREFIXES = ("com.kuhy", "dev.kuhy")

# Any com.kuhy.* / dev.kuhy.* token anywhere in config.sh, so an app added to
# any list in future is covered by this gate without editing it.
_PACKAGE_RE = re.compile(r"\b(?:com|dev)\.kuhy\.[A-Za-z0-9_.]+")

# Not yet written, and deliberately not in any list: the prefix is what has to
# allow these. This is the "and the ones that will exist in the future" half of
# the guarantee, which enumerating installed packages cannot test.
HYPOTHETICAL = ("com.kuhy.does_not_exist_yet", "dev.kuhy.does_not_exist_yet")

# Whole-label matching must not let a lookalike vendor in on the prefix.
LOOKALIKES = ("com.kuhyevil.spy", "dev.kuhyevil.spy", "com.kuhysomething")

# The one deliberate, documented exception to "every kuhy app, day and
# night": night-blocked despite matching the com.kuhy night prefix.
# see docs/DOCS-policy-lists.md#why-comkuhydufs_client-is-night-blocked
NIGHT_BLOCKED_EXCEPTION = "com.kuhy.dufs_client"


def _policy(tmp_path: pathlib.Path):
    """Load the real config.sh, with throwaway coordinates for the secrets.

    config_secrets.sh is untracked and absent in CI by design, but load_policy
    requires HOME_LAT/HOME_LON to parse. The values are irrelevant here: nothing
    under test reads them.
    """
    secrets = tmp_path / "config_secrets.sh"
    secrets.write_text("export HOME_LAT=52.0\nexport HOME_LON=21.0\n", encoding="utf-8")
    return load_policy(CONFIG, secrets)


def _declared_packages() -> set[str]:
    """Return every kuhy-owned package named anywhere in config.sh or the
    siblings it sources (the allowlists moved to config_whitelist.sh)."""
    return set(_PACKAGE_RE.findall(read_config_text(CONFIG)))


def test_config_declares_the_apps_we_expect() -> None:
    """Guard the regex itself: a scrape that silently matched nothing would
    make every other test in this file vacuously pass."""
    declared = _declared_packages()
    assert "com.kuhy.workout_app" in declared
    assert "dev.kuhy.todo" in declared
    assert len(declared) >= 8


def test_every_kuhy_app_is_allowed_day_and_night(tmp_path: pathlib.Path) -> None:
    """Every kuhy-owned package in config.sh survives both branches, except
    the one documented night-blocked exception."""
    policy = _policy(tmp_path)
    for package in sorted(_declared_packages() - {NIGHT_BLOCKED_EXCEPTION}):
        assert policy.is_allowed(package), f"{package} is hidden during the day"
        assert policy.is_allowed(package, during_curfew=True), (
            f"{package} is hidden by the night curfew"
        )


def test_night_blocked_exception_is_day_allowed_but_night_blocked(
    tmp_path: pathlib.Path,
) -> None:
    """com.kuhy.dufs_client stays available all day and away from home, but
    is denied during curfew despite matching the com.kuhy night prefix."""
    policy = _policy(tmp_path)
    assert NIGHT_BLOCKED_EXCEPTION in _declared_packages()
    assert NIGHT_BLOCKED_EXCEPTION in policy.night_blocked_packages
    assert policy.is_allowed(NIGHT_BLOCKED_EXCEPTION), (
        f"{NIGHT_BLOCKED_EXCEPTION} must stay allowed during the day"
    )
    assert not policy.is_allowed(NIGHT_BLOCKED_EXCEPTION, during_curfew=True), (
        f"{NIGHT_BLOCKED_EXCEPTION} must be denied during curfew"
    )


def test_future_kuhy_apps_are_allowed_before_they_are_listed(
    tmp_path: pathlib.Path,
) -> None:
    """An app kuhy has not written yet is allowed the moment it is installed."""
    policy = _policy(tmp_path)
    for package in HYPOTHETICAL:
        assert package not in policy.allowed_packages, (
            f"{package} is meant to be a stand-in for an unwritten app; "
            "listing it explicitly would stop this testing the prefix"
        )
        assert policy.is_allowed(package), f"{package} is not covered by the day prefix"
        assert policy.is_allowed(package, during_curfew=True), (
            f"{package} is not covered by the night prefix"
        )


def test_lookalike_vendors_are_not_allowed(tmp_path: pathlib.Path) -> None:
    """The prefix matches whole labels, so com.kuhyevil.* stays blocked."""
    policy = _policy(tmp_path)
    for package in LOOKALIKES:
        assert not policy.is_allowed(package), f"{package} must not match the prefix"
        assert not policy.is_allowed(package, during_curfew=True)


def test_vendor_prefixes_are_present_in_both_lists(tmp_path: pathlib.Path) -> None:
    """Both namespaces are allowed by prefix, day and night."""
    policy = _policy(tmp_path)
    for prefix in VENDOR_PREFIXES:
        assert prefix in policy.allowed_prefixes
        assert prefix in policy.night_allowed_prefixes


def test_no_prefix_carries_a_trailing_dot(tmp_path: pathlib.Path) -> None:
    """A trailing dot silently matches nothing; make it a hard failure."""
    policy = _policy(tmp_path)
    for prefix in (*policy.allowed_prefixes, *policy.night_allowed_prefixes):
        assert not prefix.endswith("."), (
            f"prefix {prefix!r} ends with a dot, so it matches NOTHING: "
            "matching is package == prefix or package.startswith(prefix + '.')"
        )
