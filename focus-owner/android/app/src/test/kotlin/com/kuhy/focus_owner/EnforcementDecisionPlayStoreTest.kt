// The Play Store geofence, pinned across all three branches.
//
// Play is the one package whose correct behaviour is "hidden at home, shown
// away", and it is produced by an ABSENCE in two places at once: absent from
// allowed_packages/night_allowed_packages (so AT_HOME and CURFEW hide it) and
// absent from always_blocked_packages (so AWAY shows it). Neither absence is
// visible at its call site, and adding Play to either list silently undoes the
// policy in a different direction. Hence a test rather than a comment.
//
// Why it must work away from home, measured on device 2026-08-24: infakt is
// wrapped in Google PairIP license verification and binds
// com.android.vending.licensing.ILicensingService, implemented INSIDE the
// vending package. Hide Play and infakt refuses to start at all -- so the AWAY
// branch is the window in which infakt can be used.
// See docs/DOCS-policy-lists.md#why-the-play-store-is-blocked-at-home-only

package com.kuhy.focus_owner
import com.kuhy.focus_owner.EnforcementFixtures.homeLon
import com.kuhy.focus_owner.EnforcementFixtures.latOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EnforcementDecisionPlayStoreTest {
    private val play = "com.android.vending"
    private val chrome = "com.android.chrome"

    private val installed = setOf(
        "com.launcher",
        "pl.mbank",
        "pl.infakt.infakt",
        play,
        chrome,
    )

    /** Mirrors the exported asset: Play allowed nowhere, always-blocked never. */
    private fun policy() =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {
                "latitude": ${EnforcementFixtures.homeLat},
                "longitude": ${EnforcementFixtures.homeLon},
                "radius_m": 150.0,
                "hysteresis_m": 30.0
              },
              "curfew": {"start":"23:00","end":"05:00"},
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher","pl.mbank","pl.infakt.infakt"],
              "night_allowed_packages": ["com.launcher","pl.mbank","pl.infakt.infakt"],
              "never_disable_prefixes": ["pl.infakt.infakt"],
              "workout_unblock_domains": [],
              "browser_packages": [],
              "blockable_system_packages": ["$play","$chrome"],
              "always_blocked_packages": ["$chrome"]
            }
            """.trimIndent(),
        )

    @Test
    fun `play is hidden at home during the day`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, EnforcementFixtures.homeLat, homeLon),
        )

        assertEquals(EnforcementReason.AT_HOME, decision.reason)
        assertTrue(decision.packagesToHide.contains(play))
        assertFalse(decision.packagesToShow.contains(play))
    }

    @Test
    fun `play is hidden at home during the curfew`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            // 02:00, inside the 23:00-05:00 window.
            EnforcementInputs(installed, 2 * 60, EnforcementFixtures.homeLat, homeLon),
        )

        assertEquals(EnforcementReason.CURFEW, decision.reason)
        assertTrue(decision.packagesToHide.contains(play))
    }

    @Test
    fun `play comes back away from home, or infakt cannot start`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )

        assertEquals(EnforcementReason.AWAY, decision.reason)
        assertTrue(decision.packagesToShow.contains(play))
        assertFalse(decision.packagesToHide.contains(play))
    }

    @Test
    fun `chrome stays blocked away from home while play does not`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )

        // The distinction the whole policy turns on: Play is geofenced,
        // Chrome is always-blocked. If these ever agree, one of the two lists
        // has been edited wrongly.
        assertTrue(decision.packagesToHide.contains(chrome))
        assertFalse(decision.packagesToHide.contains(play))
    }

    @Test
    fun `infakt is never hidden on any branch`() {
        val minutes = listOf(12 * 60, 2 * 60)
        val places = listOf(EnforcementFixtures.homeLat, latOffset(5000.0))

        for (minute in minutes) {
            for (lat in places) {
                val decision = EnforcementDecision.evaluate(
                    policy(),
                    EnforcementInputs(installed, minute, lat, homeLon),
                )
                assertFalse(
                    "infakt hidden at minute=$minute lat=$lat",
                    decision.packagesToHide.contains("pl.infakt.infakt"),
                )
            }
        }
    }
}
