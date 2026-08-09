package com.kuhy.focus_owner

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

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
    val currentlyEnforcing: Boolean = false,
    val workoutActive: Boolean = false,
)

/**
 * The outcome of evaluating the policy against current conditions.
 *
 * A pure function of its inputs, so it can be tested without a device, a clock
 * or a location provider. Mirrors `lib/enforcement.dart`; `PolicyParityTest`
 * pins the two against shared fixtures.
 */
data class EnforcementDecision(
    val reason: EnforcementReason,
    val packagesToHide: Set<String>,
    val packagesToShow: Set<String>,
) {
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
            val atHome = hasFix && isInside(policy, lat, lon, inputs.currentlyEnforcing)

            if (hasFix && !atHome) {
                return EnforcementDecision(
                    reason = EnforcementReason.AWAY,
                    packagesToHide = emptySet(),
                    packagesToShow = inputs.installedPackages,
                )
            }

            val duringCurfew = policy.isCurfewActive(inputs.minutesSinceMidnight)
            val reason = when {
                !hasFix -> EnforcementReason.LOCATION_UNKNOWN
                duringCurfew -> EnforcementReason.CURFEW
                else -> EnforcementReason.AT_HOME
            }

            val hide = mutableSetOf<String>()
            val show = mutableSetOf<String>()
            for (pkg in inputs.installedPackages) {
                if (policy.isAllowed(pkg, duringCurfew)) show.add(pkg) else hide.add(pkg)
            }

            if (inputs.workoutActive) {
                for (pkg in policy.workoutExemptPackages) {
                    if (hide.remove(pkg)) show.add(pkg)
                }
                return EnforcementDecision(EnforcementReason.WORKOUT, hide, show)
            }
            return EnforcementDecision(reason, hide, show)
        }

        private fun isInside(
            policy: FocusPolicy,
            latitude: Double,
            longitude: Double,
            currentlyEnforcing: Boolean,
        ): Boolean {
            val home = policy.home
            // No coordinates configured: refuse to claim the user is away.
            if (!home.hasCoordinates) return true
            val metres = haversineMetres(
                home.latitude!!,
                home.longitude!!,
                latitude,
                longitude,
            )
            val threshold = home.radiusM + if (currentlyEnforcing) home.hysteresisM else 0.0
            return metres <= threshold
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
