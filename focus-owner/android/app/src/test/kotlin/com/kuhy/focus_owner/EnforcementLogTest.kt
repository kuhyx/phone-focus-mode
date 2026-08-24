package com.kuhy.focus_owner

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The log is the only way this app can explain itself after the fact.
 *
 * `run-as` is refused on the release build device owner requires, and logcat
 * rotates -- measured empty while 82 alarms had fired. So these tests cover
 * the two properties that matter: a record survives to be read back, and no
 * coordinate ever reaches it.
 */
class EnforcementLogTest {

    @get:Rule
    val folder = TemporaryFolder()

    private val homeLat = EnforcementFixtures.homeLat
    private val homeLon = EnforcementFixtures.homeLon

    private fun log() = EnforcementLog(folder.root)

    private fun decision(
        reason: EnforcementReason = EnforcementReason.AT_HOME,
        distanceM: Double? = 42.0,
    ) = EnforcementDecision(
        reason = reason,
        packagesToHide = setOf("com.google.android.youtube"),
        packagesToShow = setOf("com.launcher"),
        distanceM = distanceM,
        thresholdM = 180.0,
        insideFence = true,
        hideReasons = mapOf("com.google.android.youtube" to HideReason.ALWAYS_BLOCKED),
    )

    private fun fix() = LocationFix(
        latitude = homeLat,
        longitude = homeLon,
        ageMs = 45_000L,
        accuracyM = 12.0,
        provider = "gps",
        outcome = FixOutcome.ACTIVE_OK,
    )

    private fun record(
        decision: EnforcementDecision = decision(),
        fix: LocationFix? = fix(),
    ) = EnforcementLog.record(
        timestampMs = 1_786_000_000_000L,
        decision = decision,
        fix = fix,
        policy = null,
        homeConfigured = true,
        permissions = setOf("android.permission.ACCESS_FINE_LOCATION"),
        hidDelta = listOf("com.google.android.youtube"),
        restoredDelta = emptyList(),
    )

    @Test
    fun `a record round-trips through the file`() {
        log().append(record())
        val lines = log().readRecent()
        assertEquals(1, lines.size)
        val parsed = JSONObject(lines.first())
        assertEquals("AT_HOME", parsed.getString("reason"))
        assertEquals(42.0, parsed.getDouble("distance_m"), 0.001)
        assertEquals(180.0, parsed.getDouble("threshold_m"), 0.001)
        assertEquals("gps", parsed.getJSONObject("fix").getString("provider"))
        assertEquals("ACTIVE_OK", parsed.getJSONObject("fix").getString("outcome"))
    }

    @Test
    fun `the record never contains coordinates`() {
        // The single most important property here: logcat and this file are
        // both reachable by anyone with the phone, and this is a home address.
        val serialised = record().toString()
        assertFalse(serialised.contains("52.2"))
        assertFalse(serialised.contains("21.0"))
        assertFalse(serialised.contains("latitude"))
        assertFalse(serialised.contains("longitude"))
    }

    @Test
    fun `every hidden package carries why it is hidden`() {
        val parsed = JSONObject(record().toString())
        val hidden = parsed.getJSONArray("hidden")
        assertEquals(1, hidden.length())
        assertEquals("com.google.android.youtube", hidden.getJSONObject(0).getString("pkg"))
        assertEquals("ALWAYS_BLOCKED", hidden.getJSONObject(0).getString("why"))
    }

    @Test
    fun `records read back newest first`() {
        val subject = log()
        subject.append(record(decision(reason = EnforcementReason.AWAY)))
        subject.append(record(decision(reason = EnforcementReason.CURFEW)))
        val lines = subject.readRecent()
        assertEquals("CURFEW", JSONObject(lines[0]).getString("reason"))
        assertEquals("AWAY", JSONObject(lines[1]).getString("reason"))
    }

    @Test
    fun `readRecent respects the limit`() {
        val subject = log()
        repeat(5) { subject.append(record()) }
        assertEquals(2, subject.readRecent(limit = 2).size)
    }

    @Test
    fun `a corrupt line is skipped rather than losing the history`() {
        // A process killed mid-append must not cost the whole log, which is
        // exactly when the log is most wanted.
        val subject = log()
        subject.append(record())
        java.io.File(folder.root, "enforcement_log.jsonl").appendText("{half-written\n")
        subject.append(record(decision(reason = EnforcementReason.AWAY)))
        val lines = subject.readRecent()
        assertEquals(2, lines.size)
        assertEquals("AWAY", JSONObject(lines[0]).getString("reason"))
    }

    @Test
    fun `an empty log reads as empty rather than failing`() {
        assertTrue(log().readRecent().isEmpty())
    }

    @Test
    fun `the file is capped and rotates on whole lines`() {
        val subject = log()
        // Enough records to trigger several rotations.
        repeat(1200) { subject.append(record()) }
        val file = java.io.File(folder.root, "enforcement_log.jsonl")
        val lines = file.readLines().filter { it.isNotBlank() }
        // Growth is bounded, but by neither constant alone: a trim drops the
        // file to KEEP_LINES (400) and appends then resume until MAX_BYTES is
        // next crossed, so the steady state is 400 plus one trim interval.
        // What matters is that 1200 appends do not accumulate.
        assertTrue("expected rotation, got ${lines.size} lines", lines.size < 1200)
        assertTrue("expected a bounded file, got ${lines.size}", lines.size <= 800)
        assertTrue(lines.isNotEmpty())
        // Rotating mid-record would make the oldest survivor unparsable.
        lines.forEach { JSONObject(it) }
    }

    @Test
    fun `a pass with no fix records the outcome rather than a bare null`() {
        val parsed = JSONObject(
            record(
                decision = decision(
                    reason = EnforcementReason.LOCATION_UNKNOWN,
                    distanceM = null,
                ),
                fix = LocationFix.unavailable(FixOutcome.TIMEOUT),
            ).toString(),
        )
        assertEquals("LOCATION_UNKNOWN", parsed.getString("reason"))
        assertTrue(parsed.isNull("distance_m"))
        // This is the field that separates "at the office, cache empty" from
        // "fuzzed fix at home" -- the two symptoms that looked identical.
        assertEquals("TIMEOUT", parsed.getJSONObject("fix").getString("outcome"))
        assertTrue(parsed.getJSONObject("fix").isNull("age_ms"))
    }
}
