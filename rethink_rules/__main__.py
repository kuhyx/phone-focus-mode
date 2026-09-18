r"""Push config_rethink.sh's domains into RethinkDNS's universal rules.

    python3 -m rethink_rules --config config_rethink.sh [--serial 23181JEGR08034]

Exit 0 when every rule is on the device (added now or already there), 1 when
any rule could not be added or read back, 2 on a config error. ``--dry-run``
prints the rules and touches nothing.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from rethink_rules.driver import apply_rules
from rethink_rules.rules import RulesConfigError, load_rules
from rethink_rules.uia import Device, UiError

EXIT_OK = 0
EXIT_FAILED_RULES = 1
EXIT_CONFIG = 2


def build_parser() -> argparse.ArgumentParser:
    """Argument parser for the CLI."""
    parser = argparse.ArgumentParser(
        prog="python3 -m rethink_rules",
        description="Add domain block rules to RethinkDNS over adb/uiautomator.",
    )
    parser.add_argument(
        "--config", type=Path, required=True, help="path to config_rethink.sh"
    )
    parser.add_argument("--serial", default=None, help="adb device serial")
    parser.add_argument(
        "--dry-run", action="store_true", help="list the rules, do not touch the phone"
    )
    return parser


def main(argv: list[str] | None = None, *, device: Device | None = None) -> int:
    """CLI entry point; ``device`` is injectable for tests."""
    args = build_parser().parse_args(argv)
    try:
        rules = load_rules(args.config)
    except (RulesConfigError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_CONFIG

    print(f"{len(rules)} rule(s) from {args.config}")
    if args.dry_run:
        for rule in rules:
            print(f"  {rule.kind.value:8s} {rule.text}")
        return EXIT_OK

    dev = device if device is not None else Device(serial=args.serial)
    try:
        report = apply_rules(dev, rules)
    except UiError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_FAILED_RULES
    print(
        f"added {len(report.added)}, already present {len(report.already_present)}, "
        f"failed {len(report.failed)}"
    )
    return EXIT_OK if report.ok else EXIT_FAILED_RULES


if __name__ == "__main__":
    sys.exit(main())
