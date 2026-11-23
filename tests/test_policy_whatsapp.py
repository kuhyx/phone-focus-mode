"""Gate: WhatsApp is visible during the day at home, hidden at night and in lockdown.

kuhy allowed it on 2026-11-23 so WhatsApp Web on the PC has a live primary
device to link to (a linked PC logs out after ~14 days with the phone app
offline, and a hidden app cannot run). Day only: night and lockdown stay shut.
"""

from __future__ import annotations

import json
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY = REPO_ROOT / "focus-owner" / "assets" / "policy.json"
PKG = "com.whatsapp"


def _policy() -> dict[str, list[str]]:
    return json.loads(POLICY.read_text(encoding="utf-8"))


def test_whatsapp_allowed_by_day() -> None:
    assert PKG in _policy()["allowed_packages"]


def test_whatsapp_hidden_at_night_and_in_lockdown() -> None:
    policy = _policy()
    assert PKG not in policy["night_allowed_packages"]
    assert PKG not in policy["lockdown_allowed_packages"]
