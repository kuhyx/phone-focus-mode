"""End-to-end proof of the hosts staging pipeline, on the PC.

This is the deterministic half of the hosts layer's verification. The other
half -- the enforcer actually bind-mounting the blocklist over
``/system/etc/hosts`` -- is root-only and CANNOT run on the Pixel 6a, which is
unrooted by design and will stay that way. ``deploy.sh`` hard-exits at its
"Verifying root access" step (``su -c id`` must return ``uid=0``) before the
staging phase is ever reached on that device. See
``docs/DOCS-hosts-layer-verification.md`` for exactly where the boundary sits.

So what these tests pin is everything up to the push: the real
``_deploy_stage_assets`` from ``deploy_phases.sh`` is executed with the hosts
generator and ``adb`` replaced by recording stubs, and the tests assert on the
exact bytes that WOULD be pushed to the device, plus the sha256 the enforcer
later verifies against.

Driving the real function matters. Asserting on a Python reimplementation of
the append would pass forever while the shell drifted; the failure this guards
against is a change to ``deploy_phases.sh`` that stops appending the
supplemental, or hashes before appending rather than after -- both of which
would leave the enforcer's tamper check disagreeing with the staged file.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import subprocess
import textwrap

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPPLEMENTAL = REPO_ROOT / "hosts_supplemental.txt"

# What the stubbed generator emits, standing in for hosts-blocker's output.
# One workout domain is included so the workout-variant strip is exercised too.
FAKE_CANONICAL = textwrap.dedent(
    """\
    # canonical stub
    0.0.0.0 example-tracker.invalid
    0.0.0.0 www.youtube.com
    0.0.0.0 another-block.invalid
    """
)


def _run_staging(tmp_path: pathlib.Path) -> dict[str, pathlib.Path]:
    """Run the real ``_deploy_stage_assets`` with stubbed generator and adb.

    Returns a mapping of remote push destination -> local copy of the bytes
    the stub recorded, so tests can assert on what the device would receive.
    """
    pushes = tmp_path / "pushes"
    pushes.mkdir()

    generator = tmp_path / "generate_hosts_file.sh"
    generator.write_text(
        "#!/bin/bash\ncat > \"$1\" <<'CANON'\n" + FAKE_CANONICAL + "CANON\n",
        encoding="utf-8",
    )
    generator.chmod(0o755)

    # adb stub: record `adb push <src> <dest>` by copying src into pushes/,
    # named after the remote basename. Everything else is a no-op success.
    bindir = tmp_path / "bin"
    bindir.mkdir()
    adb = bindir / "adb"
    adb.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/bash
            if [ "$1" = "push" ]; then
                cp "$2" "{pushes}/$(basename "$3")"
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    adb.chmod(0o755)

    driver = tmp_path / "driver.sh"
    driver.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/bash
            set -euo pipefail
            DEPLOY_DIR="{REPO_ROOT}"
            # config.sh supplies WORKOUT_UNBLOCK_DOMAINS, which the
            # workout-variant strip reads.
            FOCUS_MODE_SCRIPT_DIR="$DEPLOY_DIR" . "$DEPLOY_DIR/config.sh" >/dev/null 2>&1
            adb_cmd() {{ adb "$@"; }}
            # The staging function continues past the hosts block into the
            # GPS/secrets phase, which needs these. Stubbed so the whole real
            # function runs to completion rather than being cut short.
            adb_root() {{ return 0; }}
            REMOTE_DIR=/data/local/tmp/focus_mode
            NEEDS_GPS_FETCH=0
            . "$DEPLOY_DIR/deploy_magisk.sh"   # compute_file_hash
            . "$DEPLOY_DIR/deploy_phases.sh"
            # The tail of the phase hands off to the installer, which is a
            # different concern (and root-only on device). The hosts pipeline
            # under test has fully run by then.
            _deploy_install_files() {{ return 0; }}
            _deploy_stage_assets
            """
        ),
        encoding="utf-8",
    )

    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    env["HOSTS_GENERATOR"] = str(generator)

    result = subprocess.run(
        ["bash", str(driver)],
        capture_output=True,
        text=True,
        env=env,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode == 0, f"staging failed:\n{result.stdout}\n{result.stderr}"

    return {p.name: p for p in pushes.iterdir()}


@pytest.fixture(name="staged")
def _staged(tmp_path: pathlib.Path) -> dict[str, pathlib.Path]:
    if shutil.which("bash") is None:  # pragma: no cover - bash is always present
        pytest.skip("bash required")
    return _run_staging(tmp_path)


def test_canonical_and_hash_are_staged(staged: dict[str, pathlib.Path]) -> None:
    """The two files the enforcer needs both reach the push step."""
    assert "hosts.canonical" in staged
    assert "hosts.sha256" in staged


def test_supplemental_is_appended_verbatim(staged: dict[str, pathlib.Path]) -> None:
    """The staged canonical is generator output + supplemental, byte for byte.

    This is the append that had only ever run on the PC. If someone drops the
    ``cat "$HOSTS_SUPPLEMENTAL"`` line, the phone-only layer silently vanishes
    from every future deploy -- exactly the failure mode the fail-closed
    generator check was added for.
    """
    expected = FAKE_CANONICAL + SUPPLEMENTAL.read_text(encoding="utf-8")
    assert staged["hosts.canonical"].read_text(encoding="utf-8") == expected


def test_hash_covers_the_supplemental(staged: dict[str, pathlib.Path]) -> None:
    """The staged sha256 is taken AFTER the append, not before.

    The enforcer re-hashes the file on device and treats a mismatch as tamper.
    Hashing before the append would make every deploy look tampered with.
    """
    canonical_bytes = staged["hosts.canonical"].read_bytes()
    expected = hashlib.sha256(canonical_bytes).hexdigest()
    assert staged["hosts.sha256"].read_text(encoding="utf-8").strip() == expected


def test_workout_variant_strips_youtube_but_keeps_supplemental(
    staged: dict[str, pathlib.Path],
) -> None:
    """The workout variant drops YouTube and still carries the phone layer."""
    variant = staged["hosts.canonical.workout"].read_text(encoding="utf-8")
    assert "www.youtube.com" not in variant
    assert "example-tracker.invalid" in variant
    # The supplemental's do-not-add comment block travels with every variant.
    assert "THE PLAY STORE IS NOT BLOCKED HERE" in variant


def test_workout_variant_hash_matches_its_file(
    staged: dict[str, pathlib.Path],
) -> None:
    """The workout variant's companion hash covers the stripped bytes."""
    expected = hashlib.sha256(
        staged["hosts.canonical.workout"].read_bytes()
    ).hexdigest()
    assert (
        staged["hosts.sha256.workout"].read_text(encoding="utf-8").strip() == expected
    )


def test_missing_supplemental_fails_closed(tmp_path: pathlib.Path) -> None:
    """Staging refuses to push a hosts file that lost the phone-only layer.

    Deliberately exercised against a COPY of the repo so the real
    ``hosts_supplemental.txt`` is never moved out of the way.
    """
    fake_repo = tmp_path / "repo"
    fake_repo.mkdir()
    for name in (
        "config.sh",
        "config_paths.sh",
        "config_curfew.sh",
        "config_tether.sh",
        "config_dns.sh",
        "config_launcher.sh",
        "deploy_phases.sh",
        "deploy_magisk.sh",
        "strip_workout_hosts.py",
    ):
        shutil.copy(REPO_ROOT / name, fake_repo / name)
    # hosts_supplemental.txt deliberately NOT copied.

    generator = tmp_path / "gen.sh"
    generator.write_text(
        "#!/bin/bash\nprintf '0.0.0.0 x.invalid\\n' > \"$1\"\n", encoding="utf-8"
    )
    generator.chmod(0o755)

    bindir = tmp_path / "bin2"
    bindir.mkdir()
    adb = bindir / "adb"
    adb.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    adb.chmod(0o755)

    driver = tmp_path / "driver2.sh"
    driver.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/bash
            set -euo pipefail
            DEPLOY_DIR="{fake_repo}"
            FOCUS_MODE_SCRIPT_DIR="$DEPLOY_DIR" . "$DEPLOY_DIR/config.sh" >/dev/null 2>&1
            adb_cmd() {{ adb "$@"; }}
            . "$DEPLOY_DIR/deploy_magisk.sh"
            . "$DEPLOY_DIR/deploy_phases.sh"
            _deploy_stage_assets
            """
        ),
        encoding="utf-8",
    )

    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    env["HOSTS_GENERATOR"] = str(generator)
    result = subprocess.run(
        ["bash", str(driver)],
        capture_output=True,
        text=True,
        env=env,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode != 0
    assert "refusing to deploy" in result.stderr


def test_missing_generator_fails_closed(tmp_path: pathlib.Path) -> None:
    """An absent hosts generator gates the deploy instead of warning.

    This branch is why the hosts layer was once dead without anyone noticing.
    """
    bindir = tmp_path / "bin3"
    bindir.mkdir()
    adb = bindir / "adb"
    adb.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    adb.chmod(0o755)

    driver = tmp_path / "driver3.sh"
    driver.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/bash
            set -euo pipefail
            DEPLOY_DIR="{REPO_ROOT}"
            FOCUS_MODE_SCRIPT_DIR="$DEPLOY_DIR" . "$DEPLOY_DIR/config.sh" >/dev/null 2>&1
            adb_cmd() {{ adb "$@"; }}
            . "$DEPLOY_DIR/deploy_magisk.sh"
            . "$DEPLOY_DIR/deploy_phases.sh"
            _deploy_stage_assets
            """
        ),
        encoding="utf-8",
    )

    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    env["HOSTS_GENERATOR"] = str(tmp_path / "definitely-absent.sh")
    result = subprocess.run(
        ["bash", str(driver)],
        capture_output=True,
        text=True,
        env=env,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode != 0
    assert "hosts generator not found" in result.stderr
