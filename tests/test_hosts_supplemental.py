"""Guards on the phone-only supplemental hosts blocklist.

``hosts_supplemental.txt`` is appended to the generated canonical during
deploy staging, and the deploy hard-fails if it is missing. Its comment
carries a do-not-add list of Play and Firebase/GMS hostnames -- a comment is
not a gate, and adding any of them is precisely how infakt breaks. These
tests are that gate.

Play is blocked at the APP layer (the enforcer hides com.android.vending at
home and shows it away), which a static hosts file cannot express. Blocking
Play here would apply on the AWAY branch too, and would break infakt's PairIP
license check outright.
"""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPPLEMENTAL = REPO_ROOT / "hosts_supplemental.txt"

# Hostnames com.google.android.gms uses for push registration and the
# persistent push channel. infakt's browser-login approval tap arrives over
# these, and infakt is the app the whole Play block is designed not to break.
FORBIDDEN_HOSTS = (
    # Play licensing / checkin. infakt is PairIP-wrapped and license-checks on
    # startup; blocking this makes it refuse to open, away from home included.
    "android.clients.google.com",
    "play.googleapis.com",
    # Push registration and the persistent push channel.
    "mtalk.google.com",
    "fcm.googleapis.com",
    "android.googleapis.com",
    "firebaseinstallations.googleapis.com",
)


def _blocked_hosts() -> set[str]:
    """Return every hostname the file actually blocks, ignoring comments."""
    hosts: set[str] = set()
    for line in SUPPLEMENTAL.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        # `0.0.0.0 host` -- anything else is malformed and caught below.
        hosts.update(parts[1:])
    return hosts


def test_the_file_exists_because_the_deploy_hard_depends_on_it() -> None:
    """deploy_phases.sh exits 1 when this is missing, rather than skipping."""
    assert SUPPLEMENTAL.is_file()


def test_every_entry_is_a_null_route() -> None:
    """A line that is not `0.0.0.0 <host>` blocks nothing and looks like it does."""
    for line in SUPPLEMENTAL.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        assert stripped.startswith("0.0.0.0 "), stripped
        assert len(stripped.split()) == 2, stripped


def test_the_play_store_is_not_blocked_here() -> None:
    """Play is geofenced by the app layer, which a static hosts file cannot do.

    One file serves both at-home and away, so a Play entry here would also
    apply on the AWAY branch -- the one place the policy deliberately makes
    Play work, because infakt cannot start without it.
    """
    blocked = _blocked_hosts()
    assert not any("play" in host for host in blocked), blocked
    assert not any(host.endswith("clients.google.com") for host in blocked), blocked


def test_no_forbidden_hostname_is_ever_blocked() -> None:
    """The load-bearing one: blocking any of these silently breaks infakt.

    Checked as whole hostnames AND as suffixes, so a wildcard-ish widening
    like `googleapis.com` cannot slip past by not matching exactly.
    """
    blocked = _blocked_hosts()
    for forbidden in FORBIDDEN_HOSTS:
        assert forbidden not in blocked, f"{forbidden} is load-bearing for infakt"

    # `googleapis.com` bare would swallow fcm.googleapis.com by suffix.
    for host in blocked:
        assert host != "googleapis.com", "bare googleapis.com blocks FCM too"
        for forbidden in FORBIDDEN_HOSTS:
            assert not forbidden.endswith(f".{host}"), (
                f"{host} is a parent of {forbidden}, which infakt depends on"
            )
