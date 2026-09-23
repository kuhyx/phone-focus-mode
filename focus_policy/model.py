"""Typed policy model shared by every focus-mode enforcement backend.

The rooted implementation expresses all of this as exported shell strings in
``phone_focus_mode/config.sh``. That works for shell, but it cannot be unit
tested, and a Device Owner app written in Kotlin cannot read it at all. This
module is the language-neutral source of truth; ``export_json`` renders it into
a form any backend can load.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from focus_policy.geometry import CurfewWindow, HomeLocation, PolicyError

if TYPE_CHECKING:
    from collections.abc import Sequence
    from datetime import time

__all__ = ["CurfewWindow", "FocusPolicy", "HomeLocation", "PolicyError"]


@dataclass(frozen=True)
class FocusPolicy:
    """The complete, backend-independent focus-mode policy."""

    home: HomeLocation
    allowed_packages: frozenset[str]
    night_allowed_packages: frozenset[str]
    never_disable_prefixes: tuple[str, ...]
    workout_unblock_domains: frozenset[str] = frozenset()
    curfew: CurfewWindow | None = None
    launcher_package: str | None = None
    browser_packages: frozenset[str] = field(default_factory=frozenset)
    # Prefix-matched allowlists, for apps that ship as a family of packages.
    # Tachiyomi installs every source as its own apk, so an exact list goes
    # stale the moment a new extension is installed.
    allowed_prefixes: tuple[str, ...] = ()
    night_allowed_prefixes: tuple[str, ...] = ()
    # Packages that stay day-allowed but are denied during curfew even though
    # they match allowed_prefixes/night_allowed_prefixes. Exists because a
    # prefix (e.g. com.kuhy) is a blanket guarantee for a whole vendor
    # namespace, and a single app within it (com.kuhy.dufs_client) can need a
    # narrower night rule without weakening that guarantee for every other app
    # under the same prefix. See docs/DOCS-policy-lists.md#why-comkuhydufs-client-is-night-blocked.
    night_blocked_packages: frozenset[str] = frozenset()

    def __post_init__(self) -> None:
        """Reject policies that would lock the user out of the device."""
        if self.launcher_package and self.launcher_package not in self.allowed_packages:
            msg = (
                f"launcher {self.launcher_package!r} is not in allowed_packages; "
                "enforcing this policy would leave the device with no home screen"
            )
            raise PolicyError(msg)
        orphans = self.night_allowed_packages - self.allowed_packages
        if orphans:
            msg = (
                "night_allowed_packages must be a subset of allowed_packages; "
                f"unknown at day level: {sorted(orphans)}"
            )
            raise PolicyError(msg)
        # Same subset rule as the package lists: the curfew is meant to be a
        # tightening of the day policy, so a prefix allowed only at night would
        # invert that and be easy to miss in review.
        prefix_orphans = set(self.night_allowed_prefixes) - set(self.allowed_prefixes)
        if prefix_orphans:
            msg = (
                "night_allowed_prefixes must be a subset of allowed_prefixes; "
                f"unknown at day level: {sorted(prefix_orphans)}"
            )
            raise PolicyError(msg)
        # Day-allowed means either the exact list or a day prefix match, since
        # a package like com.kuhy.dufs_client is only exact-listed by
        # convention -- a package allowed purely through allowed_prefixes must
        # be nameable here too.
        night_blocked_unknown = {
            pkg for pkg in self.night_blocked_packages if not self.is_allowed(pkg)
        }
        if night_blocked_unknown:
            msg = (
                "night_blocked_packages must be day-allowed (exact or prefix); "
                f"unknown at day level: {sorted(night_blocked_unknown)}"
            )
            raise PolicyError(msg)
        night_blocked_conflict = (
            self.night_blocked_packages & self.night_allowed_packages
        )
        if night_blocked_conflict:
            msg = (
                "night_blocked_packages contradicts night_allowed_packages: "
                f"{sorted(night_blocked_conflict)}"
            )
            raise PolicyError(msg)
        if self.launcher_package in self.night_blocked_packages:
            msg = (
                f"launcher {self.launcher_package!r} must not be in "
                "night_blocked_packages; enforcing this policy would leave the "
                "device with no home screen during curfew"
            )
            raise PolicyError(msg)
        night_blocked_protected = {
            pkg for pkg in self.night_blocked_packages if self.is_protected(pkg)
        }
        if night_blocked_protected:
            msg = (
                "night_blocked_packages must not include protected packages "
                f"(never_disable_prefixes already guarantees them): "
                f"{sorted(night_blocked_protected)}"
            )
            raise PolicyError(msg)

    @staticmethod
    def _matches_prefix(package: str, prefixes: Sequence[str]) -> bool:
        """Return whether ``package`` is covered by any entry of ``prefixes``.

        Matched on whole labels, so ``com.android.providers`` covers
        ``com.android.providers.telephony`` but not
        ``com.android.providersomething``. Shared by every prefix list so the
        boundary rule cannot drift between them.
        """
        return any(
            package == prefix or package.startswith(f"{prefix}.") for prefix in prefixes
        )

    def is_protected(self, package: str) -> bool:
        """Return whether a package must never be disabled.

        Guards the system packages whose loss would brick core functions —
        dialer, settings, IME, SystemUI. Prefix-matched, mirroring the shell
        implementation, so that ``com.android.providers.telephony`` is covered
        by the ``com.android.providers`` entry.
        """
        return self._matches_prefix(package, self.never_disable_prefixes)

    def is_allowed(self, package: str, *, during_curfew: bool = False) -> bool:
        """Return whether a package may run under the given conditions.

        Protected system packages are always allowed. During curfew the much
        smaller ``night_allowed_packages`` set applies instead of the day list,
        and likewise for the prefix lists.
        """
        if self.is_protected(package):
            return True
        if during_curfew:
            if package in self.night_blocked_packages:
                return False
            return package in self.night_allowed_packages or self._matches_prefix(
                package,
                self.night_allowed_prefixes,
            )
        return package in self.allowed_packages or self._matches_prefix(
            package,
            self.allowed_prefixes,
        )

    def is_curfew_active(self, moment: time) -> bool:
        """Return whether the night curfew is in force at ``moment``."""
        return self.curfew is not None and self.curfew.contains(moment)

    def packages_to_block(
        self,
        installed: frozenset[str],
        *,
        during_curfew: bool = False,
    ) -> frozenset[str]:
        """Return the installed packages that this policy blocks.

        Callers pass the set actually present on the device, so a package that
        is not installed never appears in the result.
        """
        return frozenset(
            package
            for package in installed
            if not self.is_allowed(package, during_curfew=during_curfew)
        )
