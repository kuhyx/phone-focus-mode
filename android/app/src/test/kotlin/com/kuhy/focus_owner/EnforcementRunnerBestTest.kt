package com.kuhy.focus_owner

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Fix selection: which of several candidate locations a pass actually uses.
 *
 * Split out of `EnforcementLogTest`, which had grown to cover two unrelated
 * subjects. These cases never touch the log -- they pin the ordering rule that
 * decides whether a pass sees a usable fix at all, which is upstream of
 * anything being written down.
 */
class EnforcementRunnerBestTest {

    private fun candidate(ageMs: Long, accuracyM: Double?, provider: String) =
        EnforcementFixtures.candidate(ageMs, accuracyM, provider)

    private val window = 30L * 60L * 1000L

    @Test
    fun `a recent coarse fix beats an old precise one`() {
        // The ordering that matters. Sorting by accuracy first would surface
        // the morning GPS fix, the age gate would then reject it, the active
        // request times out indoors, and the pass falls to LOCATION_UNKNOWN
        // and blocks everything -- the office symptom, reintroduced.
        val chosen = EnforcementRunner.best(
            listOf(
                candidate(ageMs = 6L * 60 * 60 * 1000, accuracyM = 10.0, provider = "gps"),
                candidate(ageMs = 2L * 60 * 1000, accuracyM = 500.0, provider = "network"),
            ),
            window,
        )
        assertEquals("network", chosen?.provider)
    }

    @Test
    fun `within the window the more accurate fix wins`() {
        // A 2 km fix cannot answer a 150 m question, so a slightly older but
        // far more precise fix is the better input.
        val chosen = EnforcementRunner.best(
            listOf(
                candidate(ageMs = 10_000, accuracyM = 2000.0, provider = "network"),
                candidate(ageMs = 60_000, accuracyM = 10.0, provider = "gps"),
            ),
            window,
        )
        assertEquals("gps", chosen?.provider)
    }

    @Test
    fun `unknown accuracy loses to a known one`() {
        val chosen = EnforcementRunner.best(
            listOf(
                candidate(ageMs = 10_000, accuracyM = null, provider = "passive"),
                candidate(ageMs = 60_000, accuracyM = 80.0, provider = "gps"),
            ),
            window,
        )
        assertEquals("gps", chosen?.provider)
    }

    @Test
    fun `with nothing fresh the newest stale fix is reported`() {
        // The caller classifies it unusable regardless; returning the newest
        // makes the log record describe what was actually available.
        val chosen = EnforcementRunner.best(
            listOf(
                candidate(ageMs = 6L * 60 * 60 * 1000, accuracyM = 10.0, provider = "gps"),
                candidate(ageMs = 40L * 60 * 1000, accuracyM = 500.0, provider = "network"),
            ),
            window,
        )
        assertEquals("network", chosen?.provider)
    }

    @Test
    fun `no candidates yields no fix`() {
        assertEquals(null, EnforcementRunner.best(emptyList(), window))
    }

    @Test
    fun `a single fix is returned even with unknown accuracy`() {
        val chosen = EnforcementRunner.best(
            listOf(candidate(ageMs = 10_000, accuracyM = null, provider = "passive")),
            window,
        )
        assertEquals("passive", chosen?.provider)
    }
}
