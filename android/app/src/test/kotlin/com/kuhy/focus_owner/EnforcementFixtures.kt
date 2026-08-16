// Shared fixtures for the enforcement decision tests.
//
// Split out of EnforcementDecisionTest.kt to keep each file under the
// 250-line cap; both test classes build policies from these.

package com.kuhy.focus_owner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

internal object EnforcementFixtures {
    val homeLat = 52.2297
    val homeLon = 21.0122
    val metresPerDegreeLat = 111_320.0

    fun policy(withCoordinates: Boolean = true, curfew: String? = """{"start":"23:00","end":"05:00"}""") =
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
    fun policyWithAlwaysBlocked() =
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

    val installed = setOf(
        "com.launcher",
        "pl.mbank",
        "com.discord",
        "com.google.android.youtube",
        "com.evil",
        "com.android.settings",
    )

    fun latOffset(metres: Double) = homeLat + metres / metresPerDegreeLat

    /**
     * A candidate location fix at home, varying only in the fields that fix
     * selection actually orders on. Shared so the home coordinates stay in
     * one place: `EnforcementLogTest` asserts they never reach a log record,
     * and that assertion means less if the literals are copied around.
     */
    fun candidate(ageMs: Long, accuracyM: Double?, provider: String) = LocationFix(
        latitude = homeLat,
        longitude = homeLon,
        ageMs = ageMs,
        accuracyM = accuracyM,
        provider = provider,
        outcome = FixOutcome.CACHED_FRESH,
    )
}
