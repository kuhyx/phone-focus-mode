"""Tests for hosts-file parsing and blocklist rendering.

The cases here are drawn from real defects found in the live 194k-line
blocklist, not from imagined inputs: commented unblocks, upstream annotation
junk, and CDN subdomains that an exact-match exception filter misses.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable

from python_pkg.focus_policy.blocklist import (
    apply_exceptions,
    domain_matches,
    is_valid_domain,
    parse_hosts_blocklist,
    to_dnsmasq_conf,
    to_domain_list,
)


class TestIsValidDomain:
    """Domain syntax validation."""

    @pytest.mark.parametrize(
        "domain",
        [
            "example.com",
            "a.b.c.example.com",
            "xn--80ak6aa92e.com",
            "r1---sn-4g5e6nls.googlevideo.com",
            "1-2.co",
        ],
    )
    def test_accepts_real_domains(self, domain: str) -> None:
        """Ordinary names, punycode, and hyphen-heavy CDN names are valid."""
        assert is_valid_domain(domain)

    @pytest.mark.parametrize(
        "token",
        [
            '"spam',
            "#:",
            "#[adware.zeno]",
            "localhost",
            "",
            "-leading.com",
            "trailing-.com",
            "no_underscores.com",
            "double..dot.com",
        ],
    )
    def test_rejects_junk_and_single_labels(self, token: str) -> None:
        """Annotation junk and bare single labels are not usable domains.

        ``address=/"spam/`` makes dnsmasq refuse to start, which would take DNS
        down entirely rather than block anything.
        """
        assert not is_valid_domain(token)

    def test_rejects_overlong_name(self) -> None:
        """Names beyond the 253-character DNS limit are rejected."""
        assert not is_valid_domain(("a" * 63 + ".") * 4 + "com")


class TestParseHostsBlocklist:
    """Extraction of blocked domains from hosts-format text."""

    def test_extracts_null_routed_domains(self) -> None:
        """Entries pointing at 0.0.0.0 are blocks."""
        blocked, stats = parse_hosts_blocklist(
            "0.0.0.0 ads.example\n0.0.0.0 tracker.example\n",
        )
        assert blocked == frozenset({"ads.example", "tracker.example"})
        assert stats.blocked_domains == 2

    def test_commented_entry_unblocks(self) -> None:
        """A commented block is a deliberate exception and must win.

        ``generate_hosts_file.sh`` comments unblocks out rather than deleting
        them, so a parser that merely strips ``#`` re-blocks every site the
        user chose to allow.
        """
        blocked, stats = parse_hosts_blocklist(
            "0.0.0.0 facebook.com\n#0.0.0.0 facebook.com\n0.0.0.0 ads.example\n",
        )
        assert blocked == frozenset({"ads.example"})
        assert stats.commented_unblocks == 1

    def test_ignores_loopback_and_ipv6_housekeeping(self) -> None:
        """Non-sink mappings are not blocks; blackholing localhost breaks apps."""
        blocked, stats = parse_hosts_blocklist(
            "127.0.0.1 localhost\n::1 localhost\nff02::1 ip6-allnodes\n"
            "255.255.255.255 broadcasthost\n0.0.0.0 ads.example\n",
        )
        assert blocked == frozenset({"ads.example"})
        assert stats.skipped_non_sink == 4

    def test_rejects_annotation_junk(self) -> None:
        """Upstream provenance annotations never become domains or unblocks."""
        blocked, stats = parse_hosts_blocklist(
            '0.0.0.0 ads.example\n#[adware.zeno]\n0.0.0.0 "spam\n',
        )
        assert blocked == frozenset({"ads.example"})
        assert stats.rejected_invalid == 1

    def test_annotation_does_not_unblock_a_real_domain(self) -> None:
        """``#[cams.com]`` is an annotation, not permission to allow cams.com."""
        blocked, _ = parse_hosts_blocklist("0.0.0.0 cams.com\n#[cams.com]\n")
        assert "cams.com" in blocked

    def test_multiple_names_on_one_line(self) -> None:
        """A single sink line may list several hostnames."""
        blocked, _ = parse_hosts_blocklist("0.0.0.0 a.example b.example\n")
        assert blocked == frozenset({"a.example", "b.example"})

    def test_normalises_case_and_trailing_dot(self) -> None:
        """Names are compared lowercased and without the root dot."""
        blocked, _ = parse_hosts_blocklist("0.0.0.0 ADS.Example.\n")
        assert blocked == frozenset({"ads.example"})

    def test_ipv6_sink_counts_as_a_block(self) -> None:
        """``::`` is the IPv6 null route, equivalent to 0.0.0.0."""
        blocked, _ = parse_hosts_blocklist(":: ads.example\n")
        assert blocked == frozenset({"ads.example"})

    @pytest.mark.parametrize("text", ["", "\n\n", "#\n", "   \n", "0.0.0.0\n"])
    def test_degenerate_input_yields_nothing(self, text: str) -> None:
        """Blank lines, bare comments, and sink-only lines produce no domains."""
        blocked, _ = parse_hosts_blocklist(text)
        assert blocked == frozenset()


class TestDomainMatches:
    """Suffix matching used by the workout exception."""

    @pytest.mark.parametrize(
        "domain",
        [
            "googlevideo.com",
            "r1---sn-4g5e6nls.googlevideo.com",
            "manifest.googlevideo.com",
        ],
    )
    def test_matches_domain_and_subdomains(self, domain: str) -> None:
        """A pattern covers its whole subtree.

        YouTube serves video from dynamic ``r*---sn-*.googlevideo.com`` hosts;
        exact equality against ``googlevideo.com`` never matches them, which is
        why the shell implementation leaves playback blocked during workouts.
        """
        assert domain_matches(domain, ["googlevideo.com"])

    @pytest.mark.parametrize(
        "domain",
        ["notgooglevideo.com", "googlevideo.com.evil.net", "example.com"],
    )
    def test_rejects_lookalikes(self, domain: str) -> None:
        """Suffix matching must not be fooled by substring similarity."""
        assert not domain_matches(domain, ["googlevideo.com"])

    def test_empty_pattern_list_matches_nothing(self) -> None:
        """No patterns means no matches."""
        assert not domain_matches("example.com", [])


class TestApplyExceptions:
    """Releasing a domain subtree from the blocklist."""

    def test_releases_subtree(self) -> None:
        """Exceptions remove the domain and everything under it."""
        blocked = frozenset(
            {"googlevideo.com", "r1---sn-x.googlevideo.com", "ads.example"},
        )
        assert apply_exceptions(blocked, ["googlevideo.com"]) == frozenset(
            {"ads.example"},
        )

    def test_unrelated_blocks_survive(self) -> None:
        """An exception must not widen into unrelated domains."""
        blocked = frozenset({"pornhub.com", "doubleclick.net", "youtube.com"})
        assert apply_exceptions(blocked, ["youtube.com"]) == frozenset(
            {"pornhub.com", "doubleclick.net"},
        )

    def test_no_exceptions_returns_input(self) -> None:
        """An empty exception list leaves the blocklist untouched."""
        blocked = frozenset({"ads.example"})
        assert apply_exceptions(blocked, []) == blocked


class TestRenderers:
    """Output formats consumed by the two delivery backends."""

    def test_dnsmasq_conf_is_sorted_and_wildcarding(self) -> None:
        """``address=/domain/`` NXDOMAINs the domain and every subdomain."""
        conf = to_dnsmasq_conf({"b.example", "a.example"})
        assert conf == "address=/a.example/\naddress=/b.example/\n"

    def test_domain_list_is_sorted_one_per_line(self) -> None:
        """The VpnService fallback loads a plain sorted list."""
        assert to_domain_list({"b.example", "a.example"}) == "a.example\nb.example\n"

    @pytest.mark.parametrize("renderer", [to_dnsmasq_conf, to_domain_list])
    def test_empty_input_renders_empty(
        self,
        renderer: Callable[[Iterable[str]], str],
    ) -> None:
        """No domains renders an empty document, not a malformed one."""
        assert renderer(frozenset()) == ""
