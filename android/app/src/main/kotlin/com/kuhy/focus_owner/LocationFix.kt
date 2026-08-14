package com.kuhy.focus_owner

/** How the current fix was obtained, or why there is none. */
enum class FixOutcome {
    /** A cached fix younger than the freshness window; no request was made. */
    CACHED_FRESH,

    /** The platform answered a request made during this pass. */
    ACTIVE_OK,

    /** The request did not answer in time; any fix here is the stale cache. */
    TIMEOUT,

    /** Neither fine nor coarse location is granted. */
    NO_PERMISSION,

    /** No location provider is enabled, or the service is missing. */
    NO_PROVIDER,
}

/**
 * A location fix plus everything needed to judge and explain it.
 *
 * Age and accuracy are carried rather than discarded because they are what
 * separates a trustworthy classification from a guess: the geofence is 150 m
 * wide, so a fix that is an hour old or accurate to 2 km cannot answer the
 * question being asked of it.
 *
 * Coordinates never leave this object -- they are used to compute a distance
 * and are deliberately absent from the log record and the UI, since logcat is
 * readable by anyone with adb and this is the user's home address.
 */
data class LocationFix(
    val latitude: Double?,
    val longitude: Double?,
    /** Milliseconds since the fix was taken, from the monotonic clock. */
    val ageMs: Long,
    /** Reported accuracy radius in metres, or null when unknown. */
    val accuracyM: Double?,
    /** Provider name (`gps`, `fused`, `network`), or null when there is no fix. */
    val provider: String?,
    val outcome: FixOutcome,
) {
    /** Whether there are usable coordinates at all. */
    val hasCoordinates: Boolean get() = latitude != null && longitude != null

    /**
     * Whether this fix is recent enough to describe where the phone is now.
     *
     * The window must exceed the enforcement cadence. A shorter one would mark
     * the newest available cache stale on every pass of an idle phone, sending
     * every pass to LOCATION_UNKNOWN -- which blocks everything, the exact
     * failure this rewrite exists to remove.
     */
    fun isFresh(windowMs: Long): Boolean = hasCoordinates && ageMs <= windowMs

    companion object {
        /** A fix that could not be obtained. */
        fun unavailable(outcome: FixOutcome): LocationFix = LocationFix(
            latitude = null,
            longitude = null,
            ageMs = Long.MAX_VALUE,
            accuracyM = null,
            provider = null,
            outcome = outcome,
        )
    }
}
