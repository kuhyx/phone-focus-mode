// Lockdown activate / extend / lift records, as the in-app debug log reads them.

package com.kuhy.focus_owner
import com.kuhy.focus_owner.WorkdayLockdown.Change
import com.kuhy.focus_owner.WorkdayLockdown.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LockdownEventRecordTest {
    @Test
    fun `activation records the event and the through-date`() {
        val record = LockdownEventRecord.change(1L, Change(Outcome.ACTIVATED, null, "2026-10-02"), "2026-10-02")
        assertEquals("LOCKDOWN_ACTIVATED", record.getString("reason"))
        assertTrue("failure must be null or the UI shows NO DECISION", record.isNull("failure"))
        val lockdown = record.getJSONObject("lockdown")
        assertEquals("2026-10-02", lockdown.getString("through"))
        assertTrue(lockdown.isNull("previous"))
        assertEquals("2026-10-02", lockdown.getString("requested_until"))
        assertEquals(1L, record.getLong("ts"))
    }

    @Test
    fun `extend and unchanged keep both dates and the raw extra`() {
        val extended = LockdownEventRecord.change(2L, Change(Outcome.EXTENDED, "2026-10-02", "2026-10-04"), "2026-10-04")
        assertEquals("LOCKDOWN_EXTENDED", extended.getString("reason"))
        assertEquals("2026-10-02", extended.getJSONObject("lockdown").getString("previous"))
        val same = LockdownEventRecord.change(3L, Change(Outcome.UNCHANGED, "2026-10-04", "2026-10-04"), null)
        assertEquals("LOCKDOWN_UNCHANGED", same.getString("reason"))
        assertTrue(same.getJSONObject("lockdown").isNull("requested_until"))
    }

    @Test
    fun `lift records what it cleared`() {
        val record = LockdownEventRecord.lift(4L, "2026-10-04")
        assertEquals("LOCKDOWN_LIFTED", record.getString("reason"))
        val lockdown = record.getJSONObject("lockdown")
        assertTrue(lockdown.isNull("through"))
        assertEquals("2026-10-04", lockdown.getString("previous"))
        assertTrue(LockdownEventRecord.lift(5L, null).getJSONObject("lockdown").isNull("previous"))
    }

    @Test
    fun `event records keep every key a pass record has`() {
        val record = LockdownEventRecord.lift(6L, null)
        for (key in listOf("v", "ts", "fix", "counts", "hidden", "hid", "restored", "permissions")) {
            assertTrue(key, record.has(key))
        }
    }
}
