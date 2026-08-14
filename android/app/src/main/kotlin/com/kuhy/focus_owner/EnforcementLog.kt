package com.kuhy.focus_owner

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Append-only, size-capped record of enforcement passes.
 *
 * Read back through the platform channel rather than adb, because neither adb
 * route works on this build: `run-as` returns "package not debuggable" on the
 * release build device owner requires (see [EnforcementRunner.setHomeToCurrentLocation]),
 * and logcat rotates -- measured 2026-08-14, `adb logcat -d -s FocusOwner:V`
 * came back empty while `dumpsys alarm` showed 82 alarms had fired. An in-app
 * reader is the only durable option, so this file plus a UI is the deliverable.
 *
 * Never records coordinates. Distance in metres, fix age, accuracy and
 * provider carry everything needed to debug the geofence without writing down
 * where the user lives.
 */
class EnforcementLog(private val directory: File) {

    constructor(context: Context) : this(context.filesDir)

    private val file: File get() = File(directory, FILE_NAME)

    /**
     * Appends one record.
     *
     * Every failure is swallowed. This is instrumentation: a logging problem
     * must never be able to fail an enforcement pass, because the pass running
     * is the app's actual promise.
     */
    fun append(record: JSONObject) {
        runCatching {
            if (!directory.exists()) directory.mkdirs()
            file.appendText(record.toString() + "\n")
            rotateIfNeeded()
        }.onFailure {
            Log.w(FocusDeviceAdminReceiver.TAG, "could not append enforcement record", it)
        }
    }

    /**
     * The most recent records, newest first.
     *
     * A corrupt line is skipped rather than failing the read: a half-written
     * record from a process killed mid-append must not cost the whole history,
     * which is exactly when the history is most wanted.
     */
    fun readRecent(limit: Int = DEFAULT_LIMIT): List<String> = runCatching {
        if (!file.exists()) return emptyList()
        file.readLines()
            .asReversed()
            .asSequence()
            .filter { it.isNotBlank() }
            .filter { line -> runCatching { JSONObject(line) }.isSuccess }
            .take(limit)
            .toList()
    }.getOrElse {
        Log.w(FocusDeviceAdminReceiver.TAG, "could not read enforcement log", it)
        emptyList()
    }

    /**
     * Trims the file once it grows past [MAX_BYTES].
     *
     * Rotates by whole lines rather than truncating bytes, so the file can
     * never be left starting mid-record, which would make the oldest surviving
     * entry unparsable.
     */
    private fun rotateIfNeeded() {
        if (file.length() <= MAX_BYTES) return
        val kept = file.readLines().filter { it.isNotBlank() }.takeLast(KEEP_LINES)
        file.writeText(kept.joinToString("\n", postfix = "\n"))
    }

    companion object {
        private const val FILE_NAME = "enforcement_log.jsonl"

        /**
         * Byte size that triggers a trim.
         *
         * NOT the resulting file size, and not a ceiling. A trim drops the
         * file to [KEEP_LINES] whole records and appends resume until this is
         * crossed again, so the steady state is 400 records plus one trim
         * interval -- measured at 492 lines after 1200 appends. Measured
         * against this device (~32 sweepable packages): ~730 B/record at home
         * and ~1.7 KB during curfew when 17 apps are hidden, so the file sits
         * somewhere around 300-700 KB. Bounded, just not by this number.
         */
        private const val MAX_BYTES = 256L * 1024L

        /** The real bound: ~400 records is a little over four days at 15 min. */
        private const val KEEP_LINES = 400
        private const val DEFAULT_LIMIT = 200

        /** Schema version of the records written by this build. */
        const val SCHEMA_VERSION = 1

        /**
         * Renders one pass as a record.
         *
         * Deliberately a pure function of its arguments so it can be tested
         * without a device, and so it is obvious by inspection that no
         * coordinate reaches it: it takes a [LocationFix] but reads only the
         * age, accuracy, provider and outcome.
         */
        fun record(
            timestampMs: Long,
            decision: EnforcementDecision,
            fix: LocationFix?,
            policy: FocusPolicy?,
            homeConfigured: Boolean,
            permissions: Set<String>,
            hidDelta: List<String>,
            restoredDelta: List<String>,
            failure: String? = null,
        ): JSONObject = JSONObject().apply {
            put("v", SCHEMA_VERSION)
            put("ts", timestampMs)
            put("reason", decision.reason.name)
            put("distance_m", decision.distanceM ?: JSONObject.NULL)
            put("threshold_m", decision.thresholdM ?: JSONObject.NULL)
            put("inside_fence", decision.insideFence ?: JSONObject.NULL)
            put("home_configured", homeConfigured)
            put(
                "fix",
                JSONObject().apply {
                    put("age_ms", fix?.takeIf { it.hasCoordinates }?.ageMs ?: JSONObject.NULL)
                    put("provider", fix?.provider ?: JSONObject.NULL)
                    put("accuracy_m", fix?.accuracyM ?: JSONObject.NULL)
                    put("outcome", fix?.outcome?.name ?: JSONObject.NULL)
                },
            )
            put("permissions", JSONArray(permissions.sorted()))
            // From the clock, not inferred from the reason: at 23:30 away from
            // home the reason is AWAY while the curfew is genuinely in force.
            put("curfew_active", decision.curfewActive)
            put(
                "curfew_window",
                policy?.curfew?.let { "${hhmm(it.startMinutes)}-${hhmm(it.endMinutes)}" }
                    ?: JSONObject.NULL,
            )
            put(
                "counts",
                JSONObject().apply {
                    put("to_hide", decision.packagesToHide.size)
                    put("to_show", decision.packagesToShow.size)
                    put("hid_delta", hidDelta.size)
                    put("restored_delta", restoredDelta.size)
                },
            )
            put(
                "hidden",
                JSONArray().apply {
                    decision.packagesToHide.sorted().forEach { pkg ->
                        put(
                            JSONObject()
                                .put("pkg", pkg)
                                .put(
                                    "why",
                                    decision.hideReasons[pkg]?.name ?: "UNKNOWN",
                                ),
                        )
                    }
                },
            )
            put("hid", JSONArray(hidDelta.sorted()))
            put("restored", JSONArray(restoredDelta.sorted()))
            put("failure", failure ?: JSONObject.NULL)
        }

        /**
         * A record for a pass that produced no decision at all.
         *
         * Written from the early-return paths -- not provisioned, unreadable
         * policy -- because those are precisely the states behind "it just
         * stopped working and nothing says why", and without this they leave
         * no trace anywhere the phone can show.
         */
        fun failureRecord(timestampMs: Long, failure: String): JSONObject =
            JSONObject().apply {
                put("v", SCHEMA_VERSION)
                put("ts", timestampMs)
                put("reason", "NO_DECISION")
                put("distance_m", JSONObject.NULL)
                put("threshold_m", JSONObject.NULL)
                put("inside_fence", JSONObject.NULL)
                put("home_configured", JSONObject.NULL)
                put(
                    "fix",
                    JSONObject().apply {
                        put("age_ms", JSONObject.NULL)
                        put("provider", JSONObject.NULL)
                        put("accuracy_m", JSONObject.NULL)
                        put("outcome", JSONObject.NULL)
                    },
                )
                put("permissions", JSONArray())
                put("curfew_active", JSONObject.NULL)
                put("curfew_window", JSONObject.NULL)
                put(
                    "counts",
                    JSONObject().apply {
                        put("to_hide", 0)
                        put("to_show", 0)
                        put("hid_delta", 0)
                        put("restored_delta", 0)
                    },
                )
                put("hidden", JSONArray())
                put("hid", JSONArray())
                put("restored", JSONArray())
                put("failure", failure)
            }

        private fun hhmm(minutes: Int): String =
            "%02d:%02d".format(minutes / 60, minutes % 60)
    }
}
