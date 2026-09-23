// Workday-lockdown decision cases -- wake-alarm's missed-Tue/Wed/Thu stick.
//
// Split out of EnforcementDecisionTest.kt to keep each file under the cap.

package com.kuhy.focus_owner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkdayLockdownDecisionTest {

    private val homeLat = EnforcementFixtures.homeLat
    private val homeLon = EnforcementFixtures.homeLon
    private val metresPerDegreeLat = EnforcementFixtures.metresPerDegreeLat
    private val installed = EnforcementFixtures.installed

    private fun policy() = EnforcementFixtures.policy()

    @Test
    fun `lockdown away from home applies the strict allowlist instead of AWAY`() {
        val farLat = homeLat + 10_000 / metresPerDegreeLat
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(
                installed,
                12 * 60,
                farLat,
                homeLon,
                lockdownActive = true,
            ),
        )
        assertEquals(EnforcementReason.WORKDAY_LOCKDOWN, decision.reason)
        // com.discord and youtube are on the day allowlist but not the night
        // one -- lockdown must hide them same as a real curfew would.
        assertTrue("com.discord" in decision.packagesToHide)
        assertTrue("com.google.android.youtube" in decision.packagesToHide)
        assertTrue("pl.mbank" in decision.packagesToShow)
    }

    @Test
    fun `lockdown at home outside curfew is still strict`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(
                installed,
                12 * 60,
                homeLat,
                homeLon,
                lockdownActive = true,
            ),
        )
        assertEquals(EnforcementReason.WORKDAY_LOCKDOWN, decision.reason)
        assertFalse("not actually curfew hours", decision.curfewActive)
        assertTrue("com.discord" in decision.packagesToHide)
    }

    @Test
    fun `lockdown with no location fix is still WORKDAY_LOCKDOWN, not LOCATION_UNKNOWN`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, lockdownActive = true),
        )
        assertEquals(EnforcementReason.WORKDAY_LOCKDOWN, decision.reason)
        assertTrue("com.discord" in decision.packagesToHide)
    }

    @Test
    fun `no lockdown still returns AWAY -- unaffected regression check`() {
        val farLat = homeLat + 10_000 / metresPerDegreeLat
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, farLat, homeLon),
        )
        assertEquals(EnforcementReason.AWAY, decision.reason)
    }
}
