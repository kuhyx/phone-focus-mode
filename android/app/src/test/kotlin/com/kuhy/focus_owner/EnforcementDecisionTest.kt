package com.kuhy.focus_owner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors `test/enforcement_test.dart` case for case.
 *
 * The Kotlin decision layer exists because a background Service has no Flutter
 * engine. That duplication is only safe if the two implementations are pinned
 * to the same expectations, so these tests deliberately restate the Dart suite
 * rather than testing something adjacent. A behaviour that changes on one side
 * and not the other fails here.
 */
class EnforcementDecisionTest {

    private val homeLat = 52.2297
    private val homeLon = 21.0122
    private val metresPerDegreeLat = 111_320.0

    private fun policy(withCoordinates: Boolean = true, curfew: String? = """{"start":"23:00","end":"05:00"}""") =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {
                "latitude": ${if (withCoordinates) homeLat else "null"},
                "longitude": ${if (withCoordinates) homeLon else "null"},
                "radius_m": 150.0,
                "hysteresis_m": 30.0
              },
              "curfew": ${curfew ?: "null"},
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher","pl.mbank","com.discord","com.google.android.youtube"],
              "night_allowed_packages": ["com.launcher","pl.mbank"],
              "never_disable_prefixes": ["com.android.settings"],
              "workout_unblock_domains": ["youtube.com","googlevideo.com"],
              "browser_packages": []
            }
            """.trimIndent(),
        )

    /**
     * A policy that names YouTube as always-blocked and drops it from the
     * allowlist, since the exporter guarantees those two never overlap.
     */
    private fun policyWithAlwaysBlocked() =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {
                "latitude": $homeLat,
                "longitude": $homeLon,
                "radius_m": 150.0,
                "hysteresis_m": 30.0
              },
              "curfew": {"start":"23:00","end":"05:00"},
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher","pl.mbank","com.discord"],
              "night_allowed_packages": ["com.launcher","pl.mbank"],
              "never_disable_prefixes": ["com.android.settings"],
              "workout_unblock_domains": ["youtube.com"],
              "browser_packages": [],
              "blockable_system_packages": ["com.google.android.youtube"],
              "always_blocked_packages": ["com.google.android.youtube"]
            }
            """.trimIndent(),
        )

    private val installed = setOf(
        "com.launcher",
        "pl.mbank",
        "com.discord",
        "com.google.android.youtube",
        "com.evil",
        "com.android.settings",
    )

    private fun latOffset(metres: Double) = homeLat + metres / metresPerDegreeLat

    @Test
    fun `away from home restores everything except the always-blocked set`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        assertEquals(EnforcementReason.AWAY, decision.reason)
        // The base policy names nothing as always-blocked, so this is the
        // original behaviour: leaving home restores the whole device.
        assertTrue(decision.packagesToHide.isEmpty())
        assertEquals(installed, decision.packagesToShow)
    }

    @Test
    fun `always-blocked packages stay hidden away from home`() {
        val decision = EnforcementDecision.evaluate(
            policyWithAlwaysBlocked(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        assertEquals(EnforcementReason.AWAY, decision.reason)
        assertEquals(setOf("com.google.android.youtube"), decision.packagesToHide)
        assertFalse(decision.packagesToShow.contains("com.google.android.youtube"))
        // Everything else still comes back, which is the point of the geofence.
        assertTrue(decision.packagesToShow.contains("com.discord"))
    }

    @Test
    fun `always-blocked still counts as enforcing away from home`() {
        val decision = EnforcementDecision.evaluate(
            policyWithAlwaysBlocked(),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        // The uninstall block is keyed off isEnforcing. If AWAY reported false
        // here, leaving the house would make `adb uninstall` an off switch for
        // the one set that is meant not to have one.
        assertTrue(decision.isEnforcing)
    }

    @Test
    fun `a workout does not release an always-blocked package`() {
        val decision = EnforcementDecision.evaluate(
            policyWithAlwaysBlocked(),
            EnforcementInputs(
                installed,
                12 * 60,
                homeLat,
                homeLon,
                workoutActive = true,
            ),
        )
        assertEquals(EnforcementReason.WORKOUT, decision.reason)
        assertTrue(decision.packagesToHide.contains("com.google.android.youtube"))
    }

    @Test
    fun `at home only non-allowlisted apps are hidden`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, homeLat, homeLon),
        )
        assertEquals(EnforcementReason.AT_HOME, decision.reason)
        assertEquals(setOf("com.evil"), decision.packagesToHide)
    }

    @Test
    fun `protected packages and the launcher are never hidden`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 23 * 60 + 30, homeLat, homeLon),
        )
        assertTrue("com.android.settings" in decision.packagesToShow)
        assertTrue("com.launcher" in decision.packagesToShow)
    }

    @Test
    fun `curfew narrows the allowlist`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 23 * 60 + 30, homeLat, homeLon),
        )
        assertEquals(EnforcementReason.CURFEW, decision.reason)
        assertTrue("com.discord" in decision.packagesToHide)
        assertTrue("pl.mbank" in decision.packagesToShow)
    }

    @Test
    fun `curfew wraps past midnight`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 3 * 60, homeLat, homeLon),
        )
        assertEquals(EnforcementReason.CURFEW, decision.reason)
    }

    @Test
    fun `after curfew the day list applies again`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 6 * 60, homeLat, homeLon),
        )
        assertEquals(EnforcementReason.AT_HOME, decision.reason)
        assertTrue("com.discord" in decision.packagesToShow)
    }

    @Test
    fun `hysteresis keeps the boundary from flapping`() {
        // 160m: outside the 150m radius, inside radius+hysteresis (180m).
        val arriving = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(160.0), homeLon, currentlyEnforcing = false),
        )
        val leaving = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60, latOffset(160.0), homeLon, currentlyEnforcing = true),
        )
        assertEquals(EnforcementReason.AWAY, arriving.reason)
        assertEquals(EnforcementReason.AT_HOME, leaving.reason)
    }

    @Test
    fun `unknown location enforces rather than releasing`() {
        val decision = EnforcementDecision.evaluate(
            policy(),
            EnforcementInputs(installed, 12 * 60),
        )
        assertEquals(EnforcementReason.LOCATION_UNKNOWN, decision.reason)
        assertTrue("com.evil" in decision.packagesToHide)
    }

    @Test
    fun `redacted coordinates still enforce`() {
        val decision = EnforcementDecision.evaluate(
            policy(withCoordinates = false),
            EnforcementInputs(installed, 12 * 60, latOffset(5000.0), homeLon),
        )
        assertTrue("com.evil" in decision.packagesToHide)
    }

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
}
