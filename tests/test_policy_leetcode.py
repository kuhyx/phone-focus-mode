"""Gate: the LeetCode app is visible by day, hidden at night and in lockdown.

kuhy allowed it on 2026-11-27 ("Always. It is the app the lock wants you to
use."): the leetcode-guard phone app opens a lock problem in it. "Always" means
not only while the lock is up; night and lockdown lists stay as they were.
"""

from __future__ import annotations

import json
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY = REPO_ROOT / "focus-owner" / "assets" / "policy.json"
PKG = "com.leetcode.android"


def _policy() -> dict[str, list[str]]:
    return json.loads(POLICY.read_text(encoding="utf-8"))


def test_leetcode_allowed_by_day() -> None:
    assert PKG in _policy()["allowed_packages"]


def test_leetcode_hidden_at_night_and_in_lockdown() -> None:
    policy = _policy()
    assert PKG not in policy["night_allowed_packages"]
    assert PKG not in policy["lockdown_allowed_packages"]
