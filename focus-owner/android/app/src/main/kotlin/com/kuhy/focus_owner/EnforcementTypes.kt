package com.kuhy.focus_owner

/**
 * The vocabulary one enforcement pass is expressed in: what goes in, and the
 * two enums that explain what came out.
 *
 * Same package as [EnforcementDecision], so nothing imports these explicitly
 * and no consumer changes when they move here.
 */

/** Why a particular package is hidden. */
enum class HideReason {
    /** Hidden in every state, exempt from the geofence. */
    ALWAYS_BLOCKED,

    /** Not on the day allowlist. */
    NOT_IN_ALLOWLIST,

    /** On the day allowlist but not the shorter curfew one. */
    NOT_IN_NIGHT_ALLOWLIST,
}

/** The fence geometry behind one decision. */
data class Geofence(
    /** Metres from home, or null when no coordinates are configured. */
    val metres: Double?,
    val threshold: Double,
    val inside: Boolean,
)

/** Why enforcement is currently on or off. */
enum class EnforcementReason {
    AWAY,
    AT_HOME,
    CURFEW,
    WORKOUT,
    LOCATION_UNKNOWN,
}

/** Inputs to one enforcement decision. */
data class EnforcementInputs(
    val installedPackages: Set<String>,
    val minutesSinceMidnight: Int,
    val latitude: Double? = null,
    val longitude: Double? = null,
    /**
     * Whether the previous pass placed the phone inside the fence.
     *
     * Widens the threshold by the hysteresis margin, so a phone parked on the
     * boundary does not flap between states.
     */
    val currentlyEnforcing: Boolean = false,
    val workoutActive: Boolean = false,
    /**
     * The fix these coordinates came from, carried for the log only.
     *
     * Never consulted by [EnforcementDecision.evaluate]: staleness is applied
     * by the caller, which withholds the coordinates outright. Keeping the
     * decision a function of latitude/longitude alone is what lets it stay
     * testable without a location provider.
     */
    val fix: LocationFix? = null,
)
