package com.kuhy.focus_owner

import org.json.JSONObject

/**
 * [EnforcementLog] records for lockdown activate / extend / lift.
 *
 * Shaped like every other record (built on [EnforcementLog.failureRecord] so
 * no key is missing for the Dart parser), with the event in `reason` and the
 * dates in a `lockdown` object. The in-app debug log is the only durable
 * place this phone can show what wake-alarm asked for and what it got.
 */
object LockdownEventRecord {
    const val ACTIVATED = "LOCKDOWN_ACTIVATED"
    const val EXTENDED = "LOCKDOWN_EXTENDED"
    const val UNCHANGED = "LOCKDOWN_UNCHANGED"
    const val LIFTED = "LOCKDOWN_LIFTED"

    /** A record for one lockdown signal; [rawUntil] is the extra as sent. */
    fun change(timestampMs: Long, change: WorkdayLockdown.Change, rawUntil: String?): JSONObject =
        base(
            timestampMs,
            when (change.outcome) {
                WorkdayLockdown.Outcome.ACTIVATED -> ACTIVATED
                WorkdayLockdown.Outcome.EXTENDED -> EXTENDED
                WorkdayLockdown.Outcome.UNCHANGED -> UNCHANGED
            },
            through = change.through,
            previous = change.previous,
            requested = rawUntil,
        )

    /** A record for a lift; [previous] is the through-date it cleared, if any. */
    fun lift(timestampMs: Long, previous: String?): JSONObject =
        base(timestampMs, LIFTED, through = null, previous = previous, requested = null)

    private fun base(
        timestampMs: Long,
        event: String,
        through: String?,
        previous: String?,
        requested: String?,
    ): JSONObject = EnforcementLog.failureRecord(timestampMs, event).apply {
        put("reason", event)
        put("failure", JSONObject.NULL)
        put(
            "lockdown",
            JSONObject()
                .put("through", through ?: JSONObject.NULL)
                .put("previous", previous ?: JSONObject.NULL)
                .put("requested_until", requested ?: JSONObject.NULL),
        )
    }
}
