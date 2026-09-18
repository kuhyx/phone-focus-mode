"""Every config sibling that config.sh sources is pushed AND installed.

deploy_phases.sh and deploy_install.sh each carry a hand-written list of the
config_*.sh files. Their comments ask the editor to keep both in step with
config.sh; this test asks the machine instead. A sibling missing from either
list is staged-but-never-landed (or never staged), and a config.sh that then
sources it on the phone gets an empty list -- for config_whitelist.sh that is
"hide every app".
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
_INCLUDE = re.compile(
    r'^\. "\$SCRIPT_DIR/(config_[A-Za-z0-9_.-]+\.sh)"\s*$', re.MULTILINE
)


def _sourced_siblings() -> set[str]:
    return set(_INCLUDE.findall((REPO_ROOT / "config.sh").read_text(encoding="utf-8")))


def test_config_sh_sources_the_expected_siblings() -> None:
    """Guard the regex: a scrape matching nothing would pass vacuously."""
    assert "config_whitelist.sh" in _sourced_siblings()
    assert "config_rethink.sh" in _sourced_siblings()


def test_every_sourced_sibling_is_pushed() -> None:
    pushes = (REPO_ROOT / "deploy_phases.sh").read_text(encoding="utf-8")
    missing = {
        s for s in _sourced_siblings() if f'push "$DEPLOY_DIR/{s}"' not in pushes
    }
    assert not missing, (
        f"sourced by config.sh but not pushed by deploy_phases.sh: {sorted(missing)}"
    )


def test_every_sourced_sibling_is_installed() -> None:
    installs = (REPO_ROOT / "deploy_install.sh").read_text(encoding="utf-8")
    missing = {s for s in _sourced_siblings() if f"focus_stage/{s}" not in installs}
    assert not missing, (
        f"sourced by config.sh but not installed by deploy_install.sh: {sorted(missing)}"
    )
