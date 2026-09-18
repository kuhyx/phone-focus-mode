"""Push domain block rules into RethinkDNS on the unrooted phone.

RethinkDNS has no import path for custom domain rules (celzero/rethink-app#237),
so the rules are entered the only way that exists: through its UI, driven over
adb with uiautomator. Every tap is resolved from a fresh hierarchy dump by
resource-id, never by a remembered coordinate, and every rule is read back
through the rules screen's own search box before it counts as applied.
"""
