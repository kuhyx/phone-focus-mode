// Mirrors focus_policy/tests/test_model_policy.py's night_blocked_packages
// cases so the Kotlin isAllowed() precedence cannot drift from the Python
// model it is a second implementation of.
//
// See docs/DOCS-policy-lists.md#why-comkuhydufs_client-is-night-blocked.

package com.kuhy.focus_owner

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FocusPolicyNightBlockedTest {
    private fun policy(nightBlocked: String = "[]") =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {
                "latitude": 52.2297,
                "longitude": 21.0122,
                "radius_m": 150.0,
                "hysteresis_m": 30.0
              },
              "curfew": {"start":"23:00","end":"05:00"},
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher","pl.mbank","com.vendor.blocked"],
              "night_allowed_packages": ["com.launcher","pl.mbank"],
              "never_disable_prefixes": ["com.android.settings"],
              "allowed_prefixes": ["com.vendor"],
              "night_allowed_prefixes": ["com.vendor"],
              "night_blocked_packages": $nightBlocked,
              "workout_unblock_domains": [],
              "browser_packages": []
            }
            """.trimIndent(),
        )

    @Test
    fun `an older asset with no night_blocked_packages key parses to empty`() {
        val json = """
            {
              "schema_version": 1,
              "home": {"latitude": 52.2297, "longitude": 21.0122, "radius_m": 150.0, "hysteresis_m": 30.0},
              "curfew": null,
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher"],
              "night_allowed_packages": ["com.launcher"],
              "never_disable_prefixes": [],
              "workout_unblock_domains": [],
              "browser_packages": []
            }
        """.trimIndent()
        assertTrue(FocusPolicy.parse(json).nightBlockedPackages.isEmpty())
    }

    @Test
    fun `a package matching a night-allowed prefix is allowed at night by default`() {
        val p = policy()
        assertTrue(p.isAllowed("com.vendor.blocked", duringCurfew = true))
    }

    @Test
    fun `night_blocked_packages wins over a matching night-allowed prefix`() {
        val p = policy(nightBlocked = """["com.vendor.blocked"]""")
        assertTrue(p.isAllowed("com.vendor.blocked", duringCurfew = false))
        assertFalse(p.isAllowed("com.vendor.blocked", duringCurfew = true))
    }

    @Test
    fun `night_blocked_packages has no effect outside curfew`() {
        val p = policy(nightBlocked = """["com.vendor.blocked"]""")
        assertTrue(p.isAllowed("com.vendor.blocked", duringCurfew = false))
    }

    @Test
    fun `a protected package ignores night_blocked_packages`() {
        val p = policy(nightBlocked = """["com.android.settings"]""")
        assertTrue(p.isAllowed("com.android.settings", duringCurfew = true))
    }
}
