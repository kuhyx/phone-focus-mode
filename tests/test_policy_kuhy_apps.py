"""Gate: every app kuhy writes stays available, day and night.

`config.sh` allows `com.kuhy` and `dev.kuhy` as PREFIXES, so an app kuhy has
not written yet is allowed the moment it is installed. That guarantee is the
point of the prefix, and a comment cannot enforce it -- these tests can.

Four of these apps have already been bitten. `dev.kuhy.todo`,
`com.kuhy.punchme` and `com.kuhy.dufs_client` each earned their own section in
docs/DOCS-policy-lists.md after a build shipped inside the curfew window was
installed and then removed by the enforcer; `com.kuhy.workout_app` was the
fourth. One cause, met four times, which is what the prefix replaces.

The trailing-dot assertion is the important one. Matching is on whole labels::

    package == prefix or package.startswith(prefix + ".")

so `com.kuhy.` matches NOTHING -- not even `com.kuhy.workout_app` -- and fails
silently while still reading as correct in review.
"""

from __future__ import annotations

import pathlib
import re

from focus_policy.loader import load_policy

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
    """Return every kuhy-owned package named anywhere in config.sh."""
    return set(_PACKAGE_RE.findall(CONFIG.read_text(encoding="utf-8")))


def test_config_declares_the_apps_we_expect() -> None:
    """Guard the regex itself: a scrape that silently matched nothing would
    make every other test in this file vacuously pass."""
    declared = _declared_packages()
    assert "com.kuhy.workout_app" in declared
    assert "dev.kuhy.todo" in declared
    assert len(declared) >= 8


def test_every_kuhy_app_is_allowed_day_and_night(tmp_path: pathlib.Path) -> None:
    """Every kuhy-owned package in config.sh survives both branches."""
    policy = _policy(tmp_path)
    for package in sorted(_declared_packages()):
        assert policy.is_allowed(package), f"{package} is hidden during the day"
        assert policy.is_allowed(package, during_curfew=True), (
            f"{package} is hidden by the night curfew"
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
