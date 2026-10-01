// Through-date logic behind wake-alarm's multi-day workday lockdown.
//
// Pure functions only: the SharedPreferences wrappers need a device, the date
// rules do not, and the date rules are where a lockdown could silently
// shorten, never end, or never start.

package com.kuhy.focus_owner
import com.kuhy.focus_owner.WorkdayLockdown.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkdayLockdownTest {
    private val today = "2026-10-01"

    @Test
    fun `missing until means today, for the old extra-less sender`() {
        assertEquals(today, WorkdayLockdown.parseUntil(null, today))
    }

    @Test
    fun `invalid until means today`() {
        for (raw in listOf("", "tomorrow", "2026-10-3", "2026-13-01", "2026-02-30", "2026-10-03x", "03-10-2026")) {
            assertEquals(raw, today, WorkdayLockdown.parseUntil(raw, today))
        }
    }

    @Test
    fun `valid future until is taken as sent`() {
        assertEquals("2026-10-05", WorkdayLockdown.parseUntil("2026-10-05", today))
        assertEquals("2026-10-05", WorkdayLockdown.parseUntil(" 2026-10-05\n", today))
    }

    @Test
    fun `a far-future until is capped at today plus four days`() {
        assertEquals("2026-10-05", WorkdayLockdown.parseUntil("2026-10-05", today))
        assertEquals("2026-10-05", WorkdayLockdown.parseUntil("2026-10-06", today))
        assertEquals("2026-10-05", WorkdayLockdown.parseUntil("9999-12-31", today))
        // Across a month and a year boundary.
        assertEquals("2027-01-03", WorkdayLockdown.parseUntil("2027-06-01", "2026-12-30"))
    }

    @Test
    fun `the cap matches the contract's five calendar days`() {
        assertEquals(5, WorkdayLockdown.MAX_LOCKDOWN_DAYS)
        assertEquals("2026-03-01", WorkdayLockdown.addDays("2026-02-28", 1))
    }

    @Test
    fun `a past until still locks today -- the signal itself means today is missed`() {
        assertEquals(today, WorkdayLockdown.parseUntil("2026-09-30", today))
    }

    @Test
    fun `month and year boundaries order correctly`() {
        assertEquals("2027-01-02", WorkdayLockdown.parseUntil("2027-01-02", "2026-12-31"))
        assertTrue(WorkdayLockdown.isActive("2026-11-01", "2026-10-31"))
    }

    @Test
    fun `first signal activates`() {
        val change = WorkdayLockdown.merge(null, "2026-10-02", today)
        assertEquals(WorkdayLockdown.Change(Outcome.ACTIVATED, null, "2026-10-02"), change)
    }

    @Test
    fun `an expired stored date counts as no lockdown`() {
        val change = WorkdayLockdown.merge("2026-09-30", today, today)
        assertEquals(Outcome.ACTIVATED, change.outcome)
        assertNull(change.previous)
        assertEquals(today, change.through)
    }

    @Test
    fun `a later until extends`() {
        val change = WorkdayLockdown.merge("2026-10-02", "2026-10-04", today)
        assertEquals(WorkdayLockdown.Change(Outcome.EXTENDED, "2026-10-02", "2026-10-04"), change)
    }

    @Test
    fun `a shorter signal never shortens an existing lockdown`() {
        val change = WorkdayLockdown.merge("2026-10-04", today, today)
        assertEquals(WorkdayLockdown.Change(Outcome.UNCHANGED, "2026-10-04", "2026-10-04"), change)
    }

    @Test
    fun `the same until again is unchanged`() {
        assertEquals(Outcome.UNCHANGED, WorkdayLockdown.merge(today, today, today).outcome)
    }

    @Test
    fun `active through the last day inclusive, then self-expires`() {
        assertTrue(WorkdayLockdown.isActive("2026-10-03", "2026-10-01"))
        assertTrue(WorkdayLockdown.isActive("2026-10-03", "2026-10-03"))
        assertFalse(WorkdayLockdown.isActive("2026-10-03", "2026-10-04"))
    }

    @Test
    fun `nothing stored or a corrupt value is inactive`() {
        assertFalse(WorkdayLockdown.isActive(null, today))
        assertFalse(WorkdayLockdown.isActive("9999", today))
        assertFalse(WorkdayLockdown.isActive("garbage-later", today))
    }

    @Test
    fun `a corrupt stored value is replaced, not compared`() {
        // "x" sorts after any digit, so a naive string max would keep it forever.
        val change = WorkdayLockdown.merge("xxxx", today, today)
        assertEquals(Outcome.ACTIVATED, change.outcome)
        assertEquals(today, change.through)
    }
}
