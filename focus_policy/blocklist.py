"""Turn a hosts-format blocklist into a filter-agnostic domain list.

The rooted enforcer ships a hosts file to the phone and bind-mounts it over
``/system/etc/hosts``. An unrooted phone cannot do that, so the same blocklist
has to be delivered as *domains* — to a DoT resolver, or to a local VpnService
that answers DNS itself. This module performs that conversion.

Two properties of the generated hosts file make a naive parser wrong, and both
are handled here:

1. ``generate_hosts_file.sh`` **comments out** deliberate unblocks rather than
   deleting them (``#0.0.0.0 facebook.com``). Stripping ``#`` and taking field
   two would silently re-block every site the user chose to allow.
2. The upstream StevenBlack header carries loopback and IPv6 housekeeping lines
   (``127.0.0.1 localhost``, ``::1``, ``ff02::1``). Treating those as blocked
   domains would blackhole ``localhost``.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator

# Only entries pointing at the null route are blocks. Anything else in a hosts
# file is either loopback housekeeping or a real mapping, never a block.
_IPV4_SINK = ".".join(["0"] * 4)
_IPV6_SINK = "::"
_BLOCK_SINKS = frozenset({_IPV4_SINK, _IPV6_SINK})

_MIN_HOSTS_FIELDS = 2
_MAX_DOMAIN_LEN = 253

# A hostname label: 1-63 chars, alphanumeric or hyphen, no leading/trailing
# hyphen. A domain is two or more labels joined by dots.
_VALID_DOMAIN = re.compile(
    r"^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$",
)


def is_valid_domain(candidate: str) -> bool:
    """Return whether ``candidate`` is a syntactically usable domain name.

    The upstream StevenBlack list carries provenance annotations such as
    ``#[adware.zeno]`` and stray tokens like ``"spam``. Stripping the comment
    marker turns those into plausible-looking names, and feeding them onward
    produces a config the resolver rejects outright — dnsmasq fails to start on
    ``address=/"spam/``, which would take DNS down rather than block anything.
    They also must not be honoured as unblocks, since ``#[cams.com]`` is an
    annotation, not the user's decision to allow ``cams.com``.
    """
    return len(candidate) <= _MAX_DOMAIN_LEN and bool(_VALID_DOMAIN.match(candidate))


@dataclass(frozen=True)
class BlocklistStats:
    """Counts describing one parse, for logging and sanity checks."""

    total_lines: int
    blocked_domains: int
    commented_unblocks: int
    skipped_non_sink: int
    rejected_invalid: int


def _iter_entries(lines: Iterable[str]) -> Iterator[tuple[str, list[str], bool]]:
    """Yield ``(sink, names, was_commented)`` for every hosts-style entry.

    Commented entries are yielded too, flagged, because a commented block is an
    explicit *unblock* that must override a block of the same name.
    """
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        commented = stripped.startswith("#")
        body = stripped.lstrip("#").strip() if commented else stripped
        if not body:
            continue
        parts = body.split()
        if len(parts) < _MIN_HOSTS_FIELDS:
            continue
        yield parts[0], parts[1:], commented


def parse_hosts_blocklist(text: str) -> tuple[frozenset[str], BlocklistStats]:
    """Return the domains blocked by ``text``, plus statistics about the parse.

    A domain that appears commented out anywhere is treated as unblocked, even
    if an uncommented block for it also exists: the commented form is the
    user's deliberate exception and must win.
    """
    blocked: set[str] = set()
    unblocked: set[str] = set()
    total = skipped = rejected = 0

    for sink, names, commented in _iter_entries(text.splitlines()):
        total += 1
        if sink not in _BLOCK_SINKS:
            skipped += 1
            continue
        target = unblocked if commented else blocked
        for name in names:
            domain = name.lower().rstrip(".")
            if not is_valid_domain(domain):
                rejected += 1
                continue
            target.add(domain)

    effective = frozenset(blocked - unblocked)
    return effective, BlocklistStats(
        total_lines=total,
        blocked_domains=len(effective),
        commented_unblocks=len(unblocked),
        skipped_non_sink=skipped,
        rejected_invalid=rejected,
    )


def domain_matches(domain: str, patterns: Iterable[str]) -> bool:
    """Return whether ``domain`` equals or is a subdomain of any pattern.

    Suffix matching is what makes a workout exception actually work. YouTube
    serves video from dynamic CDN names like ``r1---sn-4g5e6nls.googlevideo.com``;
    an exact-equality check against ``googlevideo.com`` never matches them, so
    playback stays blocked. Comparing suffixes covers the whole domain tree.
    """
    candidate = domain.lower().rstrip(".")
    for pattern in patterns:
        base = pattern.lower().rstrip(".")
        if candidate == base or candidate.endswith(f".{base}"):
            return True
    return False


def apply_exceptions(
    blocked: frozenset[str],
    exceptions: Iterable[str],
) -> frozenset[str]:
    """Remove every domain covered by ``exceptions`` from ``blocked``.

    Used for the workout unblock: while a workout is in progress the YouTube
    domain tree is released. Unlike the shell implementation's exact-match
    filter, this releases subdomains too.
    """
    patterns = tuple(exceptions)
    if not patterns:
        return blocked
    return frozenset(
        domain for domain in blocked if not domain_matches(domain, patterns)
    )


def to_dnsmasq_conf(domains: Iterable[str]) -> str:
    """Render domains as dnsmasq ``address=`` directives.

    Suitable for the self-hosted DoT path, where dnsmasq is already the
    resolver behind the TLS terminator. ``address=/domain/`` returns NXDOMAIN
    for the domain and every subdomain, so the CDN-subdomain problem above
    cannot recur at the resolver.
    """
    return "".join(f"address=/{domain}/\n" for domain in sorted(domains))


def to_domain_list(domains: Iterable[str]) -> str:
    """Render domains one per line, for the VpnService fallback to load."""
    return "".join(f"{domain}\n" for domain in sorted(domains))
