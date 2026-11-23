// "Is WakeAlarm uninstalled?" -- the one input the uninstall lockdown keys on.
//
// A hidden app is installed: focus-owner hides apps itself every pass, so
// reading "hidden" as "missing" would lock the phone down over its own work.

package com.kuhy.focus_owner

import android.content.pm.ApplicationInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeAlarmPresenceTest {
    @Test
    fun `the watched package is WakeAlarm`() {
        assertEquals("com.kuhy.wake_alarm_sync", WakeAlarmPresence.PACKAGE)
    }

    @Test
    fun `not found at all is missing`() {
        assertTrue(WakeAlarmPresence.isMissing(null))
    }

    @Test
    fun `known but not installed for this user is missing`() {
        // pm uninstall --user 0 and pm uninstall -k leave the package known
        // with FLAG_INSTALLED clear.
        assertTrue(WakeAlarmPresence.isMissing(ApplicationInfo.FLAG_SYSTEM))
        assertTrue(WakeAlarmPresence.isMissing(0))
    }

    @Test
    fun `installed is present, hidden or not`() {
        // Hidden lives in privateFlags; FLAG_INSTALLED stays set.
        assertFalse(WakeAlarmPresence.isMissing(ApplicationInfo.FLAG_INSTALLED))
        assertFalse(
            WakeAlarmPresence.isMissing(ApplicationInfo.FLAG_INSTALLED or ApplicationInfo.FLAG_HAS_CODE),
        )
    }

    @Test
    fun `a query that throws counts as present`() {
        // Fail open on a broken PackageManager: a false lockdown costs the
        // whole phone for two days, a missed one costs one pass.
        assertFalse(WakeAlarmPresence.check { error("binder died") })
        assertTrue(WakeAlarmPresence.check { null })
        assertFalse(WakeAlarmPresence.check { ApplicationInfo.FLAG_INSTALLED })
    }
}
