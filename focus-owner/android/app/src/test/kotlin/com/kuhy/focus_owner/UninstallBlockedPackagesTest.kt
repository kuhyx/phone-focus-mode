// The Device Owner pins an uninstall block on the packages the policy lists,
// beside the VPN provider (2026-11-08: kuhy's running workout app).

package com.kuhy.focus_owner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UninstallBlockedPackagesTest {
    private fun policy(extra: String, vpn: String = "") =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {"latitude": 52.2297, "longitude": 21.0122, "radius_m": 150.0, "hysteresis_m": 30.0},
              "curfew": null,
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher"],
              "night_allowed_packages": ["com.launcher"],
              "never_disable_prefixes": [],
              "workout_unblock_domains": [],
              "browser_packages": [],
              "always_on_vpn_package": "$vpn"
              $extra
            }
            """.trimIndent(),
        )

    @Test
    fun `an older asset with no uninstall_blocked_packages key parses to empty`() {
        assertTrue(policy("").uninstallBlockedPackages.isEmpty())
    }

    @Test
    fun `uninstall_blocked_packages is parsed`() {
        val p = policy(""","uninstall_blocked_packages": ["com.kuhy.workout_app","com.x"]""")
        assertEquals(setOf("com.kuhy.workout_app", "com.x"), p.uninstallBlockedPackages)
    }

    @Test
    fun `targets are the listed packages plus the vpn provider`() {
        val p = policy(""","uninstall_blocked_packages": ["com.kuhy.workout_app"]""", vpn = "com.vpn")
        assertEquals(setOf("com.kuhy.workout_app", "com.vpn"), uninstallBlockTargets(p))
    }

    @Test
    fun `no policy means no targets`() {
        assertTrue(uninstallBlockTargets(null).isEmpty())
    }
}
