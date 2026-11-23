package com.kuhy.focus_owner

import android.content.Context
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * The lockdown an uninstalled WakeAlarm costs: in force while the app is
 * missing and through the day after it comes back.
 *
 * Its own prefs file, apart from [WorkdayLockdown]: wake_alarm's lift action
 * clears that one, and a freshly reinstalled WakeAlarm could send it at once.
 * Nothing but focus-owner's own release flow ends this; after a release no
 * pass runs. No day cap either: the re-assertion on every pass while the app
 * is gone is the bound.
 */
object UninstallLockdown {
    const val PREFS = "uninstall_lockdown"
    private const val KEY_THROUGH = "through"

    /**
     * The through-date after one pass. Missing: the later of the stored date
     * and tomorrow. Present: the stored date, unchanged (null when garbled).
     */
    fun throughDate(missing: Boolean, stored: String?, today: String): String? {
        val valid = stored?.takeIf { WorkdayLockdown.isValidDate(it) }
        if (!missing) return valid
        val tomorrow = WorkdayLockdown.addDays(today, 1)
        return if (valid != null && valid > tomorrow) valid else tomorrow
    }

    /** Whether [through] covers [today]. */
    fun isActive(through: String?, today: String): Boolean = WorkdayLockdown.isActive(through, today)

    /**
     * One pass's whole uninstall check: detect, update the through-date, log,
     * queue the `bypass` event. Returns whether the lockdown covers today.
     * Never throws: a broken check must not stop the pass.
     */
    @Synchronized
    fun onPass(context: Context): Boolean = runCatching {
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Calendar.getInstance().time)
        val missing = WakeAlarmPresence.isMissing(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY_THROUGH, null)
        val through = throughDate(missing, stored, today)
        if (through != stored) {
            prefs.edit().putString(KEY_THROUGH, through).commit()
            if (through != null) {
                EnforcementLog(context).append(
                    LockdownEventRecord.uninstalled(System.currentTimeMillis(), through, stored),
                )
            }
        }
        if (missing) Log.w(FocusDeviceAdminReceiver.TAG, "lockdown uninstalled through $through")
        UninstallEvents.onPass(context, missing)
        isActive(through, today)
    }.getOrElse { error ->
        Log.e(FocusDeviceAdminReceiver.TAG, "uninstall check failed", error)
        false
    }
}
