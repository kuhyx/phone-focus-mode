package com.kuhy.focus_owner

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Calendar

/**
 * The `bypass` events (cause `uninstalled`) focus-owner publishes for the PC
 * while WakeAlarm is missing, and the queue that gets them there.
 *
 * One at once when the app goes missing (it rings the PC only if that falls
 * inside a tick window), then one per later phone-local day at the first
 * pass at or after that day's alarm time. Never two on one day. The list is
 * published whole as the record's `phone_events`, newest first, 14 days
 * deep -- the shape wake-alarm's own `EventLog` writes.
 *
 * Queued durably: `unsent` is cleared only by a push that reached a backend
 * ([HeadlessPublish]), so a failed push is retried every pass and no event is
 * ever dropped. The lockdown never waits on it.
 */
object UninstallEvents {
    private const val PREFS = "uninstall_events"
    private const val KEY_EVENTS = "events"
    private const val KEY_UNSENT = "unsent"
    private const val KEY_GENERATION = "generation"
    private const val KEY_LAST_EVENT_DATE = "last_event_date"
    private const val KEY_MISSING_SINCE = "missing_since"
    private const val KEY_ALARM_HOUR = "alarm_hour"
    private const val KEY_ALARM_MINUTE = "alarm_minute"
    private const val KEY_ALARM_READ_DATE = "alarm_read_date"
    private const val KEY_FAIL_LOG_DATE = "fail_log_date"
    private const val MAX_AGE_DAYS = 14L

    /** The latest the phone can arm; used when no alarm time was read. */
    const val FALLBACK_ALARM_MINUTES = 8 * 60

    /** Seconds with an explicit offset, as wake-alarm's `EventLog.nowIso`. */
    private val FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX")

    /** Whether a pass should stamp a new event. */
    fun due(
        missing: Boolean,
        newlyMissing: Boolean,
        today: String,
        nowMinutes: Int,
        alarmMinutes: Int,
        lastEventDate: String?,
    ): Boolean = missing && lastEventDate != today && (newlyMissing || nowMinutes >= alarmMinutes)

    /** The cached alarm time in minutes, 08:00 when none or out of range. */
    fun alarmMinutes(hour: Int?, minute: Int?): Int =
        if (hour != null && minute != null && hour in 0..23 && minute in 0..59) {
            hour * 60 + minute
        } else {
            FALLBACK_ALARM_MINUTES
        }

    /** What a publish run does to the cached alarm time. */
    enum class AlarmCache { STORE, CLEAR, KEEP }

    /**
     * A read alarm is stored; a clean read that found none clears the cache
     * (so 08:00 applies, as the spec and the PC say); a failed read keeps it.
     */
    fun alarmCache(hour: Int?, minute: Int?, error: String?): AlarmCache = when {
        hour != null && minute != null -> AlarmCache.STORE
        error == null -> AlarmCache.CLEAR
        else -> AlarmCache.KEEP
    }

    /** One `bypass` event, the shape the PC's `phone_event_from` reads. */
    fun event(at: String, date: String): JSONObject = JSONObject()
        .put("at", at)
        .put("kind", "bypass")
        .put("data", JSONObject().put("cause", "uninstalled").put("date", date))

    /** [added] in front of [events], dropping anything dated over 14 days before [today]. */
    fun append(events: JSONArray, added: JSONObject, today: String): JSONArray {
        val cutoff = LocalDate.parse(today).minusDays(MAX_AGE_DAYS)
        val out = JSONArray().put(added)
        for (i in 0 until events.length()) {
            val entry = events.optJSONObject(i) ?: continue
            val day = try {
                OffsetDateTime.parse(entry.optString("at")).toLocalDate()
            } catch (_: DateTimeParseException) {
                continue
            }
            if (day.isAfter(cutoff)) out.put(entry)
        }
        return out
    }

    /** One pass: track the missing streak, stamp a due event, start a publish. */
    @Synchronized
    fun onPass(context: Context, missing: Boolean) {
        val prefs = prefs(context)
        val now = OffsetDateTime.now()
        val today = now.toLocalDate().toString()
        val newly = missing && prefs.getString(KEY_MISSING_SINCE, null) == null
        val edit = prefs.edit()
        if (!missing) edit.remove(KEY_MISSING_SINCE) else if (newly) edit.putString(KEY_MISSING_SINCE, today)
        val alarm = alarmMinutes(prefs.getIntOrNull(KEY_ALARM_HOUR), prefs.getIntOrNull(KEY_ALARM_MINUTE))
        val nowMinutes = now.hour * 60 + now.minute
        if (due(missing, newly, today, nowMinutes, alarm, prefs.getString(KEY_LAST_EVENT_DATE, null))) {
            val events = append(readEvents(prefs), event(now.format(FORMAT), today), today)
            edit.putString(KEY_EVENTS, events.toString())
                .putBoolean(KEY_UNSENT, true)
                .putLong(KEY_GENERATION, prefs.getLong(KEY_GENERATION, 0) + 1)
                .putString(KEY_LAST_EVENT_DATE, today)
            Log.w(FocusDeviceAdminReceiver.TAG, "bypass uninstalled queued for $today")
        }
        edit.commit()
        val needAlarm = missing && prefs.getString(KEY_ALARM_READ_DATE, null) != today
        if (prefs.getBoolean(KEY_UNSENT, false) || needAlarm) HeadlessPublish.start(context)
    }

    /**
     * Today's alarm instant while an event is still due today, for an exact
     * pass at it; null otherwise.
     */
    fun nextAlarmMillis(context: Context, nowMillis: Long): Long? {
        val prefs = prefs(context)
        if (prefs.getString(KEY_MISSING_SINCE, null) == null) return null
        val today = OffsetDateTime.now().toLocalDate().toString()
        if (prefs.getString(KEY_LAST_EVENT_DATE, null) == today) return null
        val minutes = alarmMinutes(prefs.getIntOrNull(KEY_ALARM_HOUR), prefs.getIntOrNull(KEY_ALARM_MINUTE))
        val at = Calendar.getInstance().apply {
            timeInMillis = nowMillis
            set(Calendar.HOUR_OF_DAY, minutes / 60)
            set(Calendar.MINUTE, minutes % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        return at.takeIf { it > nowMillis }
    }

    /** What [HeadlessPublish] hands Dart: the list, whether unsent, its generation. */
    fun pending(context: Context): Map<String, Any> {
        val prefs = prefs(context)
        return mapOf(
            "events" to readEvents(prefs).toString(),
            "unsent" to prefs.getBoolean(KEY_UNSENT, false),
            "generation" to prefs.getLong(KEY_GENERATION, 0),
        )
    }

    /**
     * Dart's result. A push that reached a backend clears `unsent`, unless an
     * event was queued meanwhile ([generation] moved on). A failure is logged
     * at most once per day; the queue stays for the next pass.
     */
    @Synchronized
    fun result(context: Context, pushed: Boolean?, generation: Long, hour: Int?, minute: Int?, error: String?) {
        val prefs = prefs(context)
        val today = OffsetDateTime.now().toLocalDate().toString()
        val edit = prefs.edit()
        when (alarmCache(hour, minute, error)) {
            AlarmCache.STORE -> edit.putInt(KEY_ALARM_HOUR, hour!!).putInt(KEY_ALARM_MINUTE, minute!!)
            AlarmCache.CLEAR -> edit.remove(KEY_ALARM_HOUR).remove(KEY_ALARM_MINUTE)
            AlarmCache.KEEP -> Unit
        }
        if (error == null) edit.putString(KEY_ALARM_READ_DATE, today)
        if (pushed == true && prefs.getLong(KEY_GENERATION, 0) == generation) edit.putBoolean(KEY_UNSENT, false)
        if (pushed == false && prefs.getString(KEY_FAIL_LOG_DATE, null) != today) {
            edit.putString(KEY_FAIL_LOG_DATE, today)
            Log.w(FocusDeviceAdminReceiver.TAG, "bypass uninstalled publish failed: $error")
            EnforcementLog(context).append(
                EnforcementLog.failureRecord(System.currentTimeMillis(), "UNINSTALL_PUBLISH_FAILED: $error"),
            )
        }
        edit.commit()
    }

    private fun readEvents(prefs: android.content.SharedPreferences): JSONArray = try {
        JSONArray(prefs.getString(KEY_EVENTS, "[]"))
    } catch (_: JSONException) {
        JSONArray()
    }

    private fun android.content.SharedPreferences.getIntOrNull(key: String): Int? =
        if (contains(key)) getInt(key, 0) else null

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
