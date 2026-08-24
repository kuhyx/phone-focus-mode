package com.kuhy.focus_owner

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Wakes the enforcement service at the moments the decision can change.
 *
 * A polling loop is the obvious design and the wrong one: Doze will skip it,
 * and skipping the 05:00 boundary means the curfew allowlist stays applied into
 * the morning — the user finds their banking app missing and no obvious cause.
 * The transitions are known ahead of time, so they get exact alarms.
 *
 * A periodic fallback runs alongside them. Alarms can be lost to a reboot, a
 * force-stop, or a system that decides otherwise; the fallback bounds how long
 * a lost alarm can leave stale policy applied. It is deliberately coarse, since
 * its job is repair rather than precision.
 */
class EnforcementScheduler(private val context: Context) {

    private val alarms = context.getSystemService(AlarmManager::class.java)

    /**
     * Schedules the next evaluation.
     *
     * Uses `setExactAndAllowWhileIdle` where permitted so Doze cannot defer a
     * boundary. When exact alarms are not permitted the inexact variant still
     * fires, just late — degraded rather than broken, which is the right
     * failure for a wellbeing tool.
     */
    fun scheduleNext(atMillis: Long = defaultNextRun()) {
        val pending = PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, EnforcementAlarmReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            alarms.canScheduleExactAlarms()
        if (exact) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        } else {
            // Not fatal: the alarm still arrives, only later. Logged because a
            // silently-inexact schedule would look like a bug at the boundary.
            Log.w(FocusDeviceAdminReceiver.TAG, "exact alarms not permitted; using inexact")
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        }
    }

    /** Cancels any pending evaluation. */
    fun cancel() {
        PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, EnforcementAlarmReceiver::class.java),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )?.let(alarms::cancel)
    }

    /**
     * The sooner of the periodic fallback and the next curfew boundary.
     *
     * The class comment has always described exact alarms at the boundaries,
     * but nothing ever computed one: both callers invoked `scheduleNext()`
     * bare, so the default was only ever `now + 15 min` and 05:00 could be
     * served up to fifteen minutes late -- exactly the "banking app still
     * missing in the morning" failure the comment warns about.
     */
    private fun defaultNextRun(): Long {
        val now = System.currentTimeMillis()
        val fallback = now + FALLBACK_INTERVAL_MS
        val boundary = nextCurfewBoundary(now) ?: return fallback
        return minOf(fallback, boundary)
    }

    /** When the curfew next opens or closes, or null when it is disabled. */
    private fun nextCurfewBoundary(now: Long): Long? {
        val curfew = runCatching { FocusPolicy.load(context) }.getOrNull()?.curfew
            ?: return null
        return listOf(curfew.startMinutes, curfew.endMinutes)
            .map { nextOccurrenceOf(it, now) }
            .min()
    }

    /** The next wall-clock instant at [minutesSinceMidnight], strictly after [now]. */
    private fun nextOccurrenceOf(minutesSinceMidnight: Int, now: Long): Long {
        val calendar = java.util.Calendar.getInstance().apply {
            timeInMillis = now
            set(java.util.Calendar.HOUR_OF_DAY, minutesSinceMidnight / 60)
            set(java.util.Calendar.MINUTE, minutesSinceMidnight % 60)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        // Rolled forward rather than clamped, so a boundary already passed
        // today schedules for tomorrow instead of firing immediately.
        if (calendar.timeInMillis <= now) {
            calendar.add(java.util.Calendar.DAY_OF_YEAR, 1)
        }
        return calendar.timeInMillis
    }

    companion object {
        private const val REQUEST_CODE = 100

        /**
         * Upper bound on how long a lost alarm can leave stale policy applied.
         *
         * Fifteen minutes trades a little battery for a much smaller window in
         * which the user is locked out of an app they should have back.
         */
        const val FALLBACK_INTERVAL_MS: Long = 15 * 60 * 1000
    }
}
