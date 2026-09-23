package com.kuhy.focus_owner

import android.content.Context
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * Persists "lock down for the rest of today" -- set by [LockdownSignalReceiver]
 * when wake-alarm signals a missed Tuesday/Wednesday/Thursday ring, read by
 * every [EnforcementRunner] pass.
 *
 * Date-keyed rather than a bare boolean so it self-expires: nothing has to
 * remember to clear it, and a stale flag surviving past midnight can never
 * lock down a day nobody asked to lock down.
 */
object WorkdayLockdown {
    private const val PREFS = "workday_lockdown"
    private const val KEY_DATE = "lockdown_date"

    /** Marks today as locked down. */
    fun activate(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DATE, today())
            .apply()
    }

    /** Whether today is the locked-down day. */
    fun isActiveToday(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_DATE, null) == today()

    private fun today(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Calendar.getInstance().time)
}
