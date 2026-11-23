// Through-date of the lockdown WakeAlarm's uninstall costs.
//
// Holds while the app is gone and through the day after it returns, with no
// cap, and only focus-owner's own release ends it -- never wake_alarm's lift,
// which a freshly reinstalled WakeAlarm could otherwise send at once.

package com.kuhy.focus_owner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UninstallLockdownTest {
    private val today = "2026-11-23"

    @Test
    fun `missing locks through tomorrow`() {
        assertEquals("2026-11-24", UninstallLockdown.throughDate(true, null, today))
    }

    @Test
    fun `present with nothing stored is no lockdown`() {
        assertNull(UninstallLockdown.throughDate(false, null, today))
        assertFalse(UninstallLockdown.isActive(null, today))
    }

    @Test
    fun `reinstalled keeps the stored through-date and ends after it`() {
        val through = UninstallLockdown.throughDate(true, null, today)
        val kept = UninstallLockdown.throughDate(false, through, today)
        assertEquals("2026-11-24", kept)
        assertTrue(UninstallLockdown.isActive(kept, today))
        assertTrue(UninstallLockdown.isActive(kept, "2026-11-24"))
        assertFalse(UninstallLockdown.isActive(kept, "2026-11-25"))
    }

    @Test
    fun `missing for a week stays active with no cap`() {
        var stored: String? = null
        var day = today
        repeat(8) {
            stored = UninstallLockdown.throughDate(true, stored, day)
            assertTrue(UninstallLockdown.isActive(stored, day))
            day = WorkdayLockdown.addDays(day, 1)
        }
        assertEquals("2026-12-01", stored)
    }

    @Test
    fun `missing never shortens a later stored date`() {
        assertEquals("2026-11-30", UninstallLockdown.throughDate(true, "2026-11-30", today))
    }

    @Test
    fun `a garbled stored date is ignored`() {
        assertEquals("2026-11-24", UninstallLockdown.throughDate(true, "soon", today))
        assertNull(UninstallLockdown.throughDate(false, "soon", today))
    }

    @Test
    fun `wake_alarm's lift does not touch it`() {
        // LockdownSignalReceiver's lift clears WorkdayLockdown's prefs only;
        // the two stores are separate files.
        assertTrue(UninstallLockdown.PREFS != "workday_lockdown")
    }
}
