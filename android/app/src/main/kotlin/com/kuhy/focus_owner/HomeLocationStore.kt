package com.kuhy.focus_owner

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * The home-location read/write half of [EnforcementRunner].
 *
 * Split out to keep [EnforcementRunner] under the 250-line cap. Owns writing
 * the current fix as home and reading it back, while [EnforcementRunner]
 * keeps the decide/apply orchestration and delegates to an instance of this
 * class.
 */
internal class HomeLocationStore(
    private val context: Context,
    private val acquireLocation: (freshWindowMs: Long, maxAccuracyM: Double?) -> LocationFix,
) {

    /**
     * Writes the current location as home.
     *
     * The app has to do this itself. `push_home_location.sh` stages the file
     * through `run-as`, which returns "package not debuggable" on the release
     * build device owner requires -- and making the build debuggable to fix
     * that would let anyone with adb edit this app's state, which is the
     * bypass the whole design exists to close.
     *
     * Deliberately not an exported intent or receiver: anything that can set
     * home from outside the app can set it to somewhere else, and the geofence
     * would then report AWAY forever with enforcement off.
     *
     * @return null on success, or a message describing why it failed.
     */
    fun setHomeToCurrentLocation(): String? {
        // Its own thresholds, so a retry actually requests a new fix rather
        // than being handed the same cached one it just rejected.
        val fix = acquireLocation(SET_HOME_MAX_AGE_MS, SET_HOME_MAX_ACCURACY_M)
        if (!fix.hasCoordinates) {
            return when (fix.outcome) {
                FixOutcome.NO_PERMISSION -> "location permission is not granted"
                FixOutcome.NO_PROVIDER -> "location services are off - turn them on"
                else -> "no location fix available - go outside or open a maps app, then retry"
            }
        }
        // A wrong home is worse than no home: it silently inverts the geofence
        // everywhere, forever, and nothing on screen would say so. So this
        // refuses anything but a fix taken now -- unlike an enforcement pass,
        // there is a user standing here who can simply retry.
        if (!fix.isFresh(SET_HOME_MAX_AGE_MS)) {
            return "only a stale fix (${fix.ageMs / 1000}s old) - wait a moment and retry"
        }
        // Unknown accuracy reads as unacceptable, matching `best` and the
        // cached-fix gate. The opposite reading would let a fix of unknown
        // precision anchor home, which silently inverts the geofence
        // everywhere and forever -- and unlike an enforcement pass, there is a
        // user present who can simply step outside and retry.
        val accuracy = fix.accuracyM ?: Double.MAX_VALUE
        if (accuracy > SET_HOME_MAX_ACCURACY_M) {
            val reported = fix.accuracyM?.toInt()?.let { "$it m" } ?: "unknown"
            return "fix accuracy is $reported (need under " +
                "${SET_HOME_MAX_ACCURACY_M.toInt()} m) - " +
                "go outside for a better signal, then retry"
        }
        return try {
            val json = JSONObject()
                .put("latitude", fix.latitude)
                .put("longitude", fix.longitude)
            File(context.filesDir, "home_location.json").writeText(json.toString())
            // Never log the coordinates: this is the user's home address and
            // logcat is world-readable to anyone with adb.
            Log.i(FocusDeviceAdminReceiver.TAG, "home location written")
            null
        } catch (e: Exception) {
            Log.e(FocusDeviceAdminReceiver.TAG, "could not write home location", e)
            e.message ?: e::class.java.simpleName
        }
    }

    /** Whether home coordinates are provisioned, without revealing them. */
    fun hasHomeLocation(): Boolean = readHomeLocation() != null

    /** Coordinates provisioned by `push_home_location.sh`, or null. */
    fun readHomeLocation(): Pair<Double, Double>? {
        val file = File(context.filesDir, "home_location.json")
        if (!file.exists()) return null
        return try {
            val json = JSONObject(file.readText())
            val lat = json.getDouble("latitude")
            val lon = json.getDouble("longitude")
            if (lat !in -90.0..90.0 || lon !in -180.0..180.0) null else lat to lon
        } catch (e: Exception) {
            // Unreadable coordinates read as "no home", which the decision
            // layer treats as location-unknown and therefore fails closed.
            Log.w(FocusDeviceAdminReceiver.TAG, "home_location.json unreadable", e)
            null
        }
    }

    private companion object {
        /**
         * Much tighter than [LocationAcquisition.FRESH_WINDOW_MS], for
         * anchoring home.
         *
         * An enforcement pass tolerates an older fix because it re-runs every
         * 15 minutes and a wrong call self-corrects. Home is written once and
         * silently inverts the geofence everywhere if it is wrong, and there
         * is a user present who can just retry -- so it demands a fresh fix.
         */
        const val SET_HOME_MAX_AGE_MS = 2L * 60L * 1000L

        /** Refuse to anchor home to a fix vaguer than the fence is wide. */
        const val SET_HOME_MAX_ACCURACY_M = 100.0
    }
}
