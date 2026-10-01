// The lockdown tier: its own exact list, narrower than the night one, with
// the night list as the fallback for an asset that predates it.

package com.kuhy.focus_owner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LockdownAllowlistTest {
    private val homeLat = EnforcementFixtures.homeLat
    private val homeLon = EnforcementFixtures.homeLon

    /** Night list has music + a com.kuhy prefix; lockdown list has maps instead. */
    private fun policy() = FocusPolicy.parse(
        """
        {
          "schema_version": 1,
          "home": {"latitude": $homeLat, "longitude": $homeLon, "radius_m": 150.0, "hysteresis_m": 30.0},
          "curfew": {"start":"23:00","end":"05:00"},
          "launcher_package": "com.launcher",
          "allowed_packages": ["com.launcher","pl.mbank","com.music","com.maps","com.discord","com.kuhy.todo"],
          "night_allowed_packages": ["com.launcher","pl.mbank","com.music"],
          "allowed_prefixes": ["com.kuhy"],
          "night_allowed_prefixes": ["com.kuhy"],
          "lockdown_allowed_packages": ["pl.mbank","com.maps","com.kuhy.todo"],
          "never_disable_prefixes": ["com.android.settings"],
          "workout_unblock_domains": [],
          "browser_packages": []
        }
        """.trimIndent(),
    )

    private val installed = setOf(
        "com.launcher", "pl.mbank", "com.music", "com.maps", "com.discord",
        "com.kuhy.todo", "com.kuhy.other", "com.android.settings",
    )

    private fun evaluate(minutes: Int, lockdown: Boolean) = EnforcementDecision.evaluate(
        policy(),
        EnforcementInputs(installed, minutes, homeLat, homeLon, lockdownActive = lockdown),
    )

    @Test
    fun `lockdown applies its own list, not the night one`() {
        val decision = evaluate(12 * 60, lockdown = true)
        assertEquals(EnforcementReason.WORKDAY_LOCKDOWN, decision.reason)
        assertEquals(
            setOf("com.launcher", "pl.mbank", "com.maps", "com.kuhy.todo", "com.android.settings"),
            decision.packagesToShow,
        )
        assertEquals(setOf("com.music", "com.discord", "com.kuhy.other"), decision.packagesToHide)
        assertTrue(decision.hideReasons.values.all { it == HideReason.NOT_IN_LOCKDOWN_ALLOWLIST })
    }

    @Test
    fun `the com_kuhy prefix does not reach through a lockdown`() {
        assertFalse(policy().isAllowed("com.kuhy.other", AllowlistTier.LOCKDOWN))
        assertTrue(policy().isAllowed("com.kuhy.other", AllowlistTier.NIGHT))
    }

    @Test
    fun `protected packages and the launcher survive a lockdown`() {
        assertTrue(policy().isAllowed("com.android.settings", AllowlistTier.LOCKDOWN))
        assertTrue(policy().isAllowed("com.launcher", AllowlistTier.LOCKDOWN))
    }

    @Test
    fun `lockdown inside curfew still uses the lockdown list`() {
        val decision = evaluate(23 * 60 + 30, lockdown = true)
        assertEquals(EnforcementReason.WORKDAY_LOCKDOWN, decision.reason)
        assertTrue(decision.curfewActive)
        assertTrue("com.maps" in decision.packagesToShow)
        assertTrue("com.music" in decision.packagesToHide)
    }

    @Test
    fun `curfew without lockdown keeps the night list`() {
        val decision = evaluate(23 * 60 + 30, lockdown = false)
        assertEquals(EnforcementReason.CURFEW, decision.reason)
        assertTrue("com.music" in decision.packagesToShow)
        assertEquals(HideReason.NOT_IN_NIGHT_ALLOWLIST, decision.hideReasons["com.maps"])
    }

    @Test
    fun `an asset without the list falls back to the night list`() {
        val old = EnforcementFixtures.policy()
        assertNull(old.lockdownAllowedPackages)
        assertTrue(old.isAllowed("pl.mbank", AllowlistTier.LOCKDOWN))
        assertFalse(old.isAllowed("com.discord", AllowlistTier.LOCKDOWN))
    }

    @Test
    fun `the shipped asset carries the lockdown list`() {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "focus-owner/assets/policy.json").isFile) dir = dir.parentFile
        val shipped = FocusPolicy.loadFile(File(dir!!, "focus-owner/assets/policy.json"))
        val list = shipped.lockdownAllowedPackages!!
        for (pkg in listOf("org.fossify.phone", "org.fossify.messages", "com.kuhy.focus_owner", "dev.kuhy.todo")) {
            assertTrue(pkg, shipped.isAllowed(pkg, AllowlistTier.LOCKDOWN))
        }
        assertFalse("com.kuhy.book_guard_app" in list)
        assertFalse(shipped.isAllowed("com.kuhy.book_guard_app", AllowlistTier.LOCKDOWN))
        assertFalse(shipped.isAllowed("com.metrolist.music", AllowlistTier.LOCKDOWN))
    }
}
