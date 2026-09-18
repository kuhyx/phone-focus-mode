"""Turn the config lists into the exact rules RethinkDNS needs.

Rethink splits the two forms: ``example.com`` blocks only the bare host and
``*.example.com`` only its subdomains, so a registrable domain needs both.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from focus_policy.blocklist import is_valid_domain
from focus_policy.loader import parse_package_list, parse_shell_assignments


class RuleKind(Enum):
    """Which chip the add-rule dialog needs."""

    DOMAIN = "domain"
    WILDCARD = "wildcard"


@dataclass(frozen=True)
class DomainRule:
    """One entry in Rethink's universal domain rules."""

    kind: RuleKind
    text: str


class RulesConfigError(ValueError):
    """The config lists contain something Rethink would reject."""


def _validated(entries: frozenset[str], *, list_name: str) -> list[str]:
    bad = sorted(e for e in entries if not is_valid_domain(e))
    if bad:
        msg = f"{list_name} holds entries that are not domains: {bad}"
        raise RulesConfigError(msg)
    return sorted(entries)


def rules_from_lists(
    domains: frozenset[str], exact_hosts: frozenset[str]
) -> list[DomainRule]:
    """Expand registrable domains into both forms; exact hosts into one."""
    rules: list[DomainRule] = []
    for domain in _validated(domains, list_name="RETHINK_BLOCK_DOMAINS"):
        rules.append(DomainRule(RuleKind.DOMAIN, domain))
        rules.append(DomainRule(RuleKind.WILDCARD, f"*.{domain}"))
    for host in _validated(exact_hosts, list_name="RETHINK_BLOCK_EXACT_HOSTS"):
        rules.append(DomainRule(RuleKind.DOMAIN, host))
    return rules


def load_rules(config_path: Path) -> list[DomainRule]:
    """Read ``config_rethink.sh`` (or any file with the two lists)."""
    values = parse_shell_assignments(config_path.read_text(encoding="utf-8"))
    domains = parse_package_list(values.get("RETHINK_BLOCK_DOMAINS", ""))
    exact = parse_package_list(values.get("RETHINK_BLOCK_EXACT_HOSTS", ""))
    if not domains and not exact:
        msg = f"{config_path}: neither RETHINK_BLOCK_DOMAINS nor RETHINK_BLOCK_EXACT_HOSTS is set"
        raise RulesConfigError(msg)
    return rules_from_lists(domains, exact)
