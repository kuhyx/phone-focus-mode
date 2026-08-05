r"""Render the focus policy as JSON for a non-Python enforcement backend.

The Device Owner app is Kotlin and cannot read ``config.sh`` or import this
package, so the policy is handed over as a generated asset:

    python3 -m python_pkg.focus_policy \\
        --config phone_focus_mode/config.sh \\
        --output focus_owner/assets/policy.json

``--redact-home`` blanks the coordinates, for a policy that will be committed
or attached to a report.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from python_pkg.focus_policy.export import policy_to_json
from python_pkg.focus_policy.loader import load_policy
from python_pkg.focus_policy.model import PolicyError


def build_parser() -> argparse.ArgumentParser:
    """Return the argument parser for the policy exporter."""
    parser = argparse.ArgumentParser(
        prog="python3 -m python_pkg.focus_policy",
        description="Render phone_focus_mode's policy as backend-neutral JSON.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        required=True,
        help="path to phone_focus_mode/config.sh",
    )
    parser.add_argument(
        "--secrets",
        type=Path,
        default=None,
        help="path to config_secrets.sh (defaults to alongside --config)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="file to write (defaults to stdout)",
    )
    parser.add_argument(
        "--redact-home",
        action="store_true",
        help="blank the home coordinates, keeping radius and hysteresis",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Render the policy, returning a process exit code."""
    args = build_parser().parse_args(argv)
    try:
        policy = load_policy(args.config, args.secrets)
    except (PolicyError, OSError) as error:
        # Written to stderr rather than raised: the caller is a shell script or
        # a build step, and a bare traceback buries the one line that says the
        # coordinates were never filled in.
        sys.stderr.write(f"error: {error}\n")
        return 1

    rendered = policy_to_json(policy, redact_home=args.redact_home) + "\n"
    if args.output is None:
        sys.stdout.write(rendered)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
        sys.stderr.write(f"wrote {args.output}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
