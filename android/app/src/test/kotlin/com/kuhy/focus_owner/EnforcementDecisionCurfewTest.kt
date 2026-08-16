// Curfew and always-blocked decision cases.
//
// Split out of EnforcementDecisionTest.kt to keep each file under the cap.

package com.kuhy.focus_owner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EnforcementDecisionCurfewTest {

    private val homeLat = EnforcementFixtures.homeLat
    private val homeLon = EnforcementFixtures.homeLon
    private val metresPerDegreeLat = EnforcementFixtures.metresPerDegreeLat

    private fun policy(withCoordinates: Boolean = true, curfew: String? = """{"start":"23:00","end":"05:00"}""") =
        EnforcementFixtures.policy(withCoordinates, curfew)

    private fun policyWithAlwaysBlocked() = EnforcementFixtures.policyWithAlwaysBlocked()

    private val installed = EnforcementFixtures.installed

    private fun latOffset(metres: Double) = EnforcementFixtures.latOffset(metres)


    @Test
    fun `workout releases youtube and nothing else`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(
                installed,
                23 * 60 + 30,
                homeLat,
                homeLon,
                workoutActive = true,
            ),
        )
        assertEquals(EnforcementReason.WORKOUT, decision.reason)
        assertTrue("com.google.android.youtube" in decision.packagesToShow)
        assertTrue("com.discord" in decision.packagesToHide)
        assertTrue("com.evil" in decision.packagesToHide)
    }

    @Test
    fun `hide and show partition the installed set`() {
        // packagesToShow is the complete allowed set, never a delta, so a
        // missed run self-repairs on the next one.
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, homeLat, homeLon),
        )
        assertEquals(installed, decision.packagesToHide + decision.packagesToShow)
        assertTrue(decision.packagesToHide.intersect(decision.packagesToShow).isEmpty())
    }

    @Test
    fun `an unknown schema version is rejected`() {
        val thrown = try {
            FocusPolicy.parse("""{"schema_version": 999, "home": {}}""")
            false
        } catch (_: PolicyFormatException) {
            true
        }
        assertTrue("expected PolicyFormatException", thrown)
    }

    @Test
    fun `prefix protection matches whole labels only`() {
        val p = policy()
        assertTrue(p.isProtected("com.android.settings"))
        assertTrue(p.isProtected("com.android.settings.sub"))
        assertFalse(p.isProtected("com.android.settingsomething"))
    }

    @Test
    fun `distance and threshold are reported so the phone can explain itself`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        // ~5 km away, and the value it was actually compared against.
        assertEquals(5000.0, decision.distanceM!!, 50.0)
        assertEquals(150.0, decision.thresholdM!!, 0.001)
        assertEquals(false, decision.insideFence)
    }

    @Test
    fun `hysteresis widens the threshold only for a phone already inside`() {
        // 160 m out: outside the bare 150 m radius, inside 150 + 30. This is
        // what stops a phone parked on the boundary from flapping.
        val outside = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(
                installed,
                12 * 60,
                latOffset(160.0),
                homeLon,
                currentlyEnforcing = false,
            ),
        )
        assertEquals(150.0, outside.thresholdM!!, 0.001)
        assertEquals(EnforcementReason.AWAY, outside.reason)

        val inside = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(
                installed,
                12 * 60,
                latOffset(160.0),
                homeLon,
                currentlyEnforcing = true,
            ),
        )
        assertEquals(180.0, inside.thresholdM!!, 0.001)
        assertEquals(EnforcementReason.AT_HOME, inside.reason)
    }

    @Test
    fun `an unanswerable fence reports null rather than outside`() {
        // No fix at all. Recording "outside" here would drop hysteresis on the
        // next pass at exactly the moment the input is least reliable.
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latitude = null, longitude = null),
        )
        assertEquals(EnforcementReason.LOCATION_UNKNOWN, decision.reason)
        assertEquals(null, decision.insideFence)
        assertEquals(null, decision.distanceM)
    }

    @Test
    fun `no home coordinates reports an unknown distance, not zero`() {
        // Fabricating 0 m would read on screen as "you are exactly at home".
        val decision = EnforcementDecision.evaluate(
            policy(withCoordinates = false),
            EnforcementInputs(installed, 12 * 60, homeLat, homeLon),
        )
        assertEquals(null, decision.distanceM)
        assertEquals(true, decision.insideFence)
    }

    @Test
    fun `every hidden package carries a reason`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, homeLat, homeLon),
        )
        // The UI lists these per package, so a gap would render as a blank
        // explanation next to a hidden app.
        assertEquals(decision.packagesToHide, decision.hideReasons.keys)
        assertTrue(
            decision.hideReasons.values.all { it == HideReason.NOT_IN_ALLOWLIST },
        )
    }

    @Test
    fun `curfew hiding is attributed to the night list`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 23 * 60 + 30, homeLat, homeLon),
        )
        assertEquals(EnforcementReason.CURFEW, decision.reason)
        // com.discord is day-allowed but not night-allowed, so the distinction
        // matters: "not in allowlist" would be misleading.
        assertEquals(
            HideReason.NOT_IN_NIGHT_ALLOWLIST,
            decision.hideReasons["com.discord"],
        )
    }

    @Test
    fun `always-blocked is attributed as such even when away`() {
        val decision = EnforcementDecision.evaluate(
            policyWithAlwaysBlocked(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        assertEquals(EnforcementReason.AWAY, decision.reason)
        assertEquals(
            HideReason.ALWAYS_BLOCKED,
            decision.hideReasons["com.google.android.youtube"],
        )
    }

    @Test
    fun `allowed prefixes cover a family of packages`() {
        val p = FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {
                "latitude": $homeLat, "longitude": $homeLon,
                "radius_m": 150.0, "hysteresis_m": 30.0
              },
              "curfew": {"start":"23:00","end":"05:00"},
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher"],
              "night_allowed_packages": ["com.launcher"],
              "never_disable_prefixes": [],
              "workout_unblock_domains": [],
              "allowed_prefixes": ["eu.kanade.tachiyomi"],
              "night_allowed_prefixes": ["eu.kanade.tachiyomi"],
              "browser_packages": []
            }
            """.trimIndent(),
        )
        assertTrue(p.isAllowed("eu.kanade.tachiyomi.sy", false))
        assertTrue(p.isAllowed("eu.kanade.tachiyomi.extension.all.mangadex", false))
        // Chosen 2026-08-14: manga stays available during the curfew.
        assertTrue(p.isAllowed("eu.kanade.tachiyomi.sy", true))
        // Whole labels only.
        assertFalse(p.isAllowed("eu.kanade.tachiyomisomething", false))
    }

    @Test
    fun `an asset without prefix keys still parses`() {
        // Back-compat: a policy rendered before prefixes existed must degrade
        // to exact matching rather than failing to parse at all, since an
        // unparsable policy skips the pass entirely.
        assertTrue(policy().allowedPrefixes.isEmpty())
        assertTrue(policy().nightAllowedPrefixes.isEmpty())
    }
}
