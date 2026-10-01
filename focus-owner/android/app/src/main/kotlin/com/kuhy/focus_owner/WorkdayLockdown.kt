package com.kuhy.focus_owner

import android.content.Context
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * Persists wake-alarm's workday lockdown as an inclusive through-date -- set
 * by [LockdownSignalReceiver] on a missed Tuesday/Wednesday/Thursday ring,
 * cleared by its lift action, read by every [EnforcementRunner] pass.
 *
 * Date-keyed rather than a bare boolean so it self-expires: nothing has to
 * remember to clear it, and a stale value surviving past its last day can
 * never lock down a day nobody asked to lock down.
 *
 * The prefs key is the one the single-day version used. Its stored value was
 * already a date meaning "locked through today", so an upgrade installed mid-
 * lockdown keeps that day locked instead of silently releasing it.
 *
 * The date logic lives in pure functions taking `today` as a string, so the
 * JVM unit tests can pin it without a device or a clock.
 */
object WorkdayLockdown {
    private const val PREFS = "workday_lockdown"
    private const val KEY_THROUGH = "lockdown_date"
    private const val DATE_PATTERN = "yyyy-MM-dd"
    private val DATE_SHAPE = Regex("""\d{4}-\d{2}-\d{2}""")

    /**
     * Longest lockdown one signal may set, today included -- the contract's
     * `STICK_LOCKDOWN_MAX_DAYS` (wake-alarm Stakes.kt / _constants.py).
     */
    const val MAX_LOCKDOWN_DAYS = 5

    /** What one lockdown signal did to the stored through-date. */
    enum class Outcome { ACTIVATED, EXTENDED, UNCHANGED }

    /** The result of applying one signal, for the log. */
    data class Change(
        val outcome: Outcome,
        /** The through-date in force before the signal, or null if none was. */
        val previous: String?,
        /** The through-date in force after it. */
        val through: String,
    )

    /**
     * Applies a lockdown signal whose `until` extra was [rawUntil].
     *
     * Synchronized and committed synchronously so two signals arriving
     * together cannot both read the old date and one of them be lost.
     */
    @Synchronized
    fun activate(context: Context, rawUntil: String?): Change {
        val today = today()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val change = merge(prefs.getString(KEY_THROUGH, null), parseUntil(rawUntil, today), today)
        prefs.edit().putString(KEY_THROUGH, change.through).commit()
        return change
    }

    /** Clears any lockdown now, returning the through-date it had, if active. */
    @Synchronized
    fun lift(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previous = prefs.getString(KEY_THROUGH, null)?.takeIf { isActive(it, today()) }
        prefs.edit().remove(KEY_THROUGH).commit()
        return previous
    }

    /** Whether a lockdown covers today. */
    fun isActive(context: Context): Boolean =
        isActive(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_THROUGH, null),
            today(),
        )

    /**
     * The through-date a signal asks for.
     *
     * Missing or malformed means today, so the old extra-less sender keeps
     * working and a garbled one still locks the day it was sent for. A valid
     * date in the past also means today: the signal itself says today is a
     * missed day, and a stale `until` must not make it a no-op.
     *
     * Capped at today + [MAX_LOCKDOWN_DAYS] - 1, so a sender bug cannot lock
     * the phone indefinitely; only a lift would otherwise end that.
     */
    fun parseUntil(raw: String?, today: String): String {
        val parsed = raw?.trim()?.takeIf { isValidDate(it) } ?: return today
        return minOf(maxOf(parsed, today), addDays(today, MAX_LOCKDOWN_DAYS - 1))
    }

    /** [date] (`yyyy-MM-dd`) plus [days] calendar days. */
    fun addDays(date: String, days: Int): String {
        val format = SimpleDateFormat(DATE_PATTERN, Locale.US).apply { isLenient = false }
        val calendar = Calendar.getInstance().apply {
            time = format.parse(date)!!
            add(Calendar.DAY_OF_MONTH, days)
        }
        return format.format(calendar.time)
    }

    /**
     * Combines the stored through-date with a requested one.
     *
     * Takes the later of the two: a one-day signal arriving during a longer
     * lockdown must never shorten it. An expired stored date counts as none.
     */
    fun merge(stored: String?, requested: String, today: String): Change {
        val previous = stored?.takeIf { isActive(it, today) }
        return when {
            previous == null -> Change(Outcome.ACTIVATED, null, requested)
            requested > previous -> Change(Outcome.EXTENDED, previous, requested)
            else -> Change(Outcome.UNCHANGED, previous, previous)
        }
    }

    /**
     * Whether [through] covers [today]. ISO dates order correctly as strings.
     *
     * A malformed stored value is inactive rather than an error: failing open
     * on corrupt prefs costs one lockdown, failing closed could cost the
     * phone indefinitely.
     */
    fun isActive(through: String?, today: String): Boolean =
        through != null && isValidDate(through) && today <= through

    /**
     * Whether [value] is a real calendar date in `yyyy-MM-dd` form.
     *
     * The shape check comes first because `SimpleDateFormat.parse` ignores
     * trailing garbage, and the round trip rejects what non-lenient parsing
     * still lets through (single-digit fields).
     */
    fun isValidDate(value: String): Boolean {
        if (!DATE_SHAPE.matches(value)) return false
        val format = SimpleDateFormat(DATE_PATTERN, Locale.US).apply { isLenient = false }
        return try {
            format.format(format.parse(value)!!) == value
        } catch (_: ParseException) {
            false
        }
    }

    private fun today(): String =
        SimpleDateFormat(DATE_PATTERN, Locale.US).format(Calendar.getInstance().time)
}
