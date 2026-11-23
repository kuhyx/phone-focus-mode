// When focus-owner stamps a `bypass` with cause `uninstalled`.
//
// One at once when WakeAlarm goes missing, then one per later day at the
// first pass at or after that day's alarm time, never two on one day.

package com.kuhy.focus_owner

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UninstallEventsTest {
    private val day1 = "2026-11-23"
    private val day2 = "2026-11-24"
    private val alarm = 7 * 60 + 30

    @Test
    fun `the first pass that sees it missing stamps one at any hour`() {
        assertTrue(UninstallEvents.due(true, newlyMissing = true, day1, 3 * 60, alarm, lastEventDate = null))
    }

    @Test
    fun `present stamps nothing`() {
        assertFalse(UninstallEvents.due(false, newlyMissing = false, day1, 9 * 60, alarm, null))
    }

    @Test
    fun `never two on one day`() {
        assertFalse(UninstallEvents.due(true, newlyMissing = false, day1, 9 * 60, alarm, day1))
        assertFalse(UninstallEvents.due(true, newlyMissing = true, day1, 9 * 60, alarm, day1))
    }

    @Test
    fun `a later day waits for the alarm time`() {
        assertFalse(UninstallEvents.due(true, newlyMissing = false, day2, alarm - 1, alarm, day1))
        assertTrue(UninstallEvents.due(true, newlyMissing = false, day2, alarm, alarm, day1))
        assertTrue(UninstallEvents.due(true, newlyMissing = false, day2, 23 * 60, alarm, day1))
    }

    @Test
    fun `no alarm time falls back to 08 00`() {
        assertEquals(8 * 60, UninstallEvents.alarmMinutes(null, null))
        assertEquals(8 * 60, UninstallEvents.alarmMinutes(25, 0))
        assertEquals(6 * 60 + 45, UninstallEvents.alarmMinutes(6, 45))
    }

    @Test
    fun `the event has the shape the PC reads`() {
        val event = UninstallEvents.event("2026-11-24T07:30:05.000+01:00", day2)
        assertEquals("bypass", event.getString("kind"))
        assertEquals("2026-11-24T07:30:05.000+01:00", event.getString("at"))
        assertEquals("uninstalled", event.getJSONObject("data").getString("cause"))
        assertEquals(day2, event.getJSONObject("data").getString("date"))
    }

    @Test
    fun `appended events stay newest first and drop entries past 14 days`() {
        val old = UninstallEvents.event("2026-11-01T08:00:00.000+01:00", "2026-11-01")
        val mid = UninstallEvents.event("2026-11-20T08:00:00.000+01:00", "2026-11-20")
        val list = JSONArray().put(mid).put(old)
        val added = UninstallEvents.event("2026-11-24T07:30:00.000+01:00", day2)
        val out = UninstallEvents.append(list, added, day2)
        assertEquals(2, out.length())
        assertEquals(day2, (out[0] as JSONObject).getJSONObject("data").getString("date"))
        assertEquals("2026-11-20", (out[1] as JSONObject).getJSONObject("data").getString("date"))
    }

    @Test
    fun `a clean read with no alarm clears the cache, a failed one keeps it`() {
        assertEquals(UninstallEvents.AlarmCache.CLEAR, UninstallEvents.alarmCache(null, null, error = null))
        assertEquals(UninstallEvents.AlarmCache.KEEP, UninstallEvents.alarmCache(null, null, error = "offline"))
        assertEquals(UninstallEvents.AlarmCache.STORE, UninstallEvents.alarmCache(7, 30, error = null))
        assertEquals(UninstallEvents.AlarmCache.STORE, UninstallEvents.alarmCache(7, 30, error = "push failed"))
    }
}
