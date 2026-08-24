package com.kuhy.focus_owner

/**
 * The policy's value types: the schema version this build understands, the
 * failure it raises, and the two records [FocusPolicy] is built from.
 *
 * Same package as FocusPolicy, so nothing imports these explicitly and no call
 * site changes by their moving here.
 */

/** Schema version this build understands. */
const val SUPPORTED_SCHEMA_VERSION = 1

/** Thrown when the bundled policy cannot be trusted. */
class PolicyFormatException(message: String) : Exception(message)

/** A nightly window that may wrap midnight (23:00 -> 05:00). */
data class CurfewWindow(val startMinutes: Int, val endMinutes: Int) {
    /**
     * Whether [minutesSinceMidnight] falls inside the window.
     *
     * Wrapping windows are the normal case, so "inside" means at or after the
     * start *or* before the end, not both.
     */
    fun contains(minutesSinceMidnight: Int): Boolean =
        if (startMinutes <= endMinutes) {
            minutesSinceMidnight in startMinutes until endMinutes
        } else {
            minutesSinceMidnight >= startMinutes || minutesSinceMidnight < endMinutes
        }
}

/** The home anchor. Coordinates are null in a redacted policy. */
data class HomeLocation(
    val latitude: Double?,
    val longitude: Double?,
    val radiusM: Double,
    val hysteresisM: Double,
) {
    /**
     * Whether this policy carries real coordinates.
     *
     * The committed asset is redacted, so enforcement must check this rather
     * than treating a missing coordinate as (0, 0) — that would put "home" in
     * the Atlantic and silently disable the gate.
     */
    val hasCoordinates: Boolean get() = latitude != null && longitude != null
}
