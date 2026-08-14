package com.kuhy.focus_owner

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

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

/**
 * The outcome of evaluating the policy against current conditions.
 *
 * A pure function of its inputs, so it can be tested without a device, a clock
 * or a location provider.
 *
 * This is the ONLY implementation that enforces anything. `lib/enforcement.dart`
 * used to be described here as a mirror pinned by a `PolicyParityTest`; no such
 * test ever existed, and the two had silently drifted -- the Dart copy has no
 * always-blocked concept at all, so it would report YouTube as visible while it
 * is in fact hidden. The UI therefore renders the record this class produces
 * rather than re-deciding anything, which removes the drift instead of policing
 * it.
 */
data class EnforcementDecision(
    val reason: EnforcementReason,
    val packagesToHide: Set<String>,
    val packagesToShow: Set<String>,
    /**
     * Metres from home, or null when there was no fix or no coordinates.
     *
     * Reported so the phone can explain itself. Coordinates are deliberately
     * NOT carried: a distance is enough to debug the geofence, and logcat is
     * readable by anyone with adb.
     */
    val distanceM: Double? = null,
    /** The value [distanceM] was compared against, including hysteresis. */
    val thresholdM: Double? = null,
    /**
     * Whether the fence returned a verdict, or null when it could not.
     *
     * Null is not the same as false: it means the question was unanswerable,
     * so the caller leaves the previous verdict standing instead of recording
     * "outside" and losing hysteresis at the worst moment.
     */
    val insideFence: Boolean? = null,
    /** Why each hidden package is hidden, for the UI and the log. */
    val hideReasons: Map<String, HideReason> = emptyMap(),
    /**
     * Whether the clock is inside the curfew window.
     *
     * Carried separately from [reason] because the two disagree: at 23:30 away
     * from home the reason is AWAY, and inferring curfew from the enum would
     * report "not in curfew" in exactly the branches where it is least obvious.
     */
    val curfewActive: Boolean = false,
) {
    /**
     * Whether this pass leaves anything hidden.
     *
     * Derived rather than stored, which matters for the always-blocked set:
     * AWAY still hides those, so it still counts as enforcing, and the
     * uninstall block keyed off this stays on away from home. Were this tied
     * to the reason instead, leaving the house would lift the block while
     * YouTube stayed hidden -- making `adb uninstall` the off switch for the
     * one thing that is meant not to have one.
     */
    val isEnforcing: Boolean get() = packagesToHide.isNotEmpty()

    companion object {
        private const val EARTH_RADIUS_M = 6_371_000.0

        /**
         * Decides which packages should be hidden right now.
         *
         * Fail-closed on unknown location, matching `focus_daemon.sh`, which
         * logs "Location unavailable - defaulting to focus mode". Losing GPS
         * must not be a way to switch enforcement off.
         *
         * [packagesToShow] is always the complete allowed set, never a delta,
         * so a missed run repairs itself on the next one. Failing to hide is a
         * mild disappointment; failing to *unhide* strands the user without a
         * dialer or a banking app after a reboot during curfew.
         */
        fun evaluate(policy: FocusPolicy, inputs: EnforcementInputs): EnforcementDecision {
            val lat = inputs.latitude
            val lon = inputs.longitude
            val hasFix = lat != null && lon != null
            val fence = if (hasFix) {
                geofence(policy, lat, lon, inputs.currentlyEnforcing)
            } else {
                null
            }
            val atHome = fence?.inside ?: false
            // Computed before the AWAY return so every branch can report it.
            // The window is a property of the clock, not of where the phone is.
            val duringCurfew = policy.isCurfewActive(inputs.minutesSinceMidnight)

            // Exempt from every branch below, including AWAY and WORKOUT.
            // Restricted to packages actually present, so the sets stay a
            // description of this device rather than of the policy.
            val alwaysBlocked = inputs.installedPackages
                .intersect(policy.alwaysBlockedPackages)
                .filterNot { policy.isProtected(it) }
                .toSet()

            if (hasFix && !atHome) {
                return EnforcementDecision(
                    reason = EnforcementReason.AWAY,
                    packagesToHide = alwaysBlocked,
                    packagesToShow = inputs.installedPackages - alwaysBlocked,
                    distanceM = fence?.metres,
                    thresholdM = fence?.threshold,
                    insideFence = fence?.inside,
                    hideReasons = alwaysBlocked.associateWith { HideReason.ALWAYS_BLOCKED },
                    curfewActive = duringCurfew,
                )
            }

            val reason = when {
                !hasFix -> EnforcementReason.LOCATION_UNKNOWN
                duringCurfew -> EnforcementReason.CURFEW
                else -> EnforcementReason.AT_HOME
            }

            val hide = mutableSetOf<String>()
            val show = mutableSetOf<String>()
            val why = mutableMapOf<String, HideReason>()
            for (pkg in inputs.installedPackages) {
                if (pkg in alwaysBlocked) {
                    hide.add(pkg)
                    why[pkg] = HideReason.ALWAYS_BLOCKED
                } else if (policy.isAllowed(pkg, duringCurfew)) {
                    show.add(pkg)
                } else {
                    hide.add(pkg)
                    why[pkg] = if (duringCurfew) {
                        HideReason.NOT_IN_NIGHT_ALLOWLIST
                    } else {
                        HideReason.NOT_IN_ALLOWLIST
                    }
                }
            }

            if (inputs.workoutActive) {
                for (pkg in policy.workoutExemptPackages) {
                    // A workout exemption must not become a way to reach the
                    // always-blocked set, or "go for a run" is the off switch.
                    if (pkg in alwaysBlocked) continue
                    if (hide.remove(pkg)) {
                        show.add(pkg)
                        why.remove(pkg)
                    }
                }
                return EnforcementDecision(
                    reason = EnforcementReason.WORKOUT,
                    packagesToHide = hide,
                    packagesToShow = show,
                    distanceM = fence?.metres,
                    thresholdM = fence?.threshold,
                    insideFence = fence?.inside,
                    hideReasons = why,
                    curfewActive = duringCurfew,
                )
            }
            return EnforcementDecision(
                reason = reason,
                packagesToHide = hide,
                packagesToShow = show,
                distanceM = fence?.metres,
                thresholdM = fence?.threshold,
                insideFence = fence?.inside,
                hideReasons = why,
                curfewActive = duringCurfew,
            )
        }

        /**
         * Evaluates the fence, returning the geometry as well as the verdict.
         *
         * The distance and the threshold are returned rather than discarded so
         * the app can say *why* it decided what it decided. Without them the
         * three states are indistinguishable from outside, which is what made
         * the original misbehaviour impossible to diagnose from the phone.
         */
        private fun geofence(
            policy: FocusPolicy,
            latitude: Double,
            longitude: Double,
            currentlyEnforcing: Boolean,
        ): Geofence {
            val home = policy.home
            val threshold = home.radiusM + if (currentlyEnforcing) home.hysteresisM else 0.0
            // No coordinates configured: refuse to claim the user is away.
            // Reported as inside with an unknown distance, so the UI can say
            // "no home set" rather than presenting a fabricated 0 m.
            if (!home.hasCoordinates) {
                return Geofence(metres = null, threshold = threshold, inside = true)
            }
            val metres = haversineMetres(
                home.latitude!!,
                home.longitude!!,
                latitude,
                longitude,
            )
            return Geofence(metres, threshold, inside = metres <= threshold)
        }

        private fun haversineMetres(
            lat1: Double,
            lon1: Double,
            lat2: Double,
            lon2: Double,
        ): Double {
            val dLat = Math.toRadians(lat2 - lat1)
            val dLon = Math.toRadians(lon2 - lon1)
            val a = sin(dLat / 2) * sin(dLat / 2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
                sin(dLon / 2) * sin(dLon / 2)
            return 2 * EARTH_RADIUS_M * asin(sqrt(a))
        }
    }
}
