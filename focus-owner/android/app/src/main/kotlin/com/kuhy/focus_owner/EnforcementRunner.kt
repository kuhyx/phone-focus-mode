package com.kuhy.focus_owner

import android.content.Context
import android.util.Log
import java.util.Calendar

/**
 * Gathers the inputs for one enforcement pass and applies the result.
 *
 * Split out of [EnforcementService] so the service stays a thin lifecycle
 * wrapper and this part can be reasoned about — and eventually instrumented —
 * on its own. Location-fix acquisition itself lives in [LocationAcquisition];
 * this class keeps the decide/apply orchestration and delegates to it.
 */
class EnforcementRunner(private val context: Context) {

    private val locationAcquisition = LocationAcquisition(context)
    private val homeLocationStore = HomeLocationStore(context) { freshWindowMs, maxAccuracyM ->
        acquireLocation(freshWindowMs = freshWindowMs, maxAccuracyM = maxAccuracyM)
    }

    /**
     * Inputs from the current pass, carried from [decide] to [apply].
     *
     * The record needs both halves: the fix and whether home is configured are
     * only visible while deciding, the hide/show deltas only while applying.
     * This is why [EnforcementService] uses ONE runner for both calls -- a
     * second instance would log a pass with no fix metadata at all.
     */
    private var pass: PassContext? = null

    private data class PassContext(
        val fix: LocationFix,
        val homeConfigured: Boolean,
        val policy: FocusPolicy?,
    )

    /** Builds the decision, or null when the policy cannot be read. */
    fun decide(): EnforcementDecision? {
        val policy = try {
            FocusPolicy.load(context)
        } catch (e: Exception) {
            // A policy that cannot be parsed must never be treated as an empty
            // allowlist: that would hide every app on the device.
            Log.e(FocusDeviceAdminReceiver.TAG, "policy unreadable", e)
            return null
        }

        val home = homeLocationStore.readHomeLocation()
        // Acquired even when no home is configured, so the log can tell
        // "never provisioned" apart from "could not get a fix" -- previously
        // both produced an identical LOCATION_UNKNOWN with nothing to
        // distinguish them.
        val fix = acquireLocation()
        val fresh = fix.isFresh(FRESH_WINDOW_MS)
        pass = PassContext(fix = fix, homeConfigured = home != null, policy = policy)
        val calendar = Calendar.getInstance()
        val minutes = calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)

        // Coordinates come from app-private storage, not the committed asset,
        // which ships redacted. Substituted in here so the decision layer sees
        // one coherent policy.
        val effective = if (home == null) {
            policy
        } else {
            policy.copy(
                home = policy.home.copy(latitude = home.first, longitude = home.second),
            )
        }

        return EnforcementDecision.evaluate(
            effective,
            EnforcementInputs(
                installedPackages = sweepablePackages(context, effective),
                minutesSinceMidnight = minutes,
                // A stale fix is withheld entirely rather than passed with its
                // age attached: it must not be able to classify the phone as
                // AWAY. Fail-closed here is only safe because acquireLocation
                // now actively requests a fix, so "stale" is the exception
                // rather than the steady state.
                latitude = if (fresh) fix.latitude else null,
                longitude = if (fresh) fix.longitude else null,
                // Keyed off whether the last pass placed the phone inside the
                // fence, NOT off whether it hid anything. AWAY still hides the
                // always-blocked set, so the old `wasEnforcing()` was true in
                // every state and the threshold was permanently radius +
                // hysteresis -- biasing every borderline call toward AT_HOME.
                currentlyEnforcing = wasInsideFence(),
                workoutActive = false,
                fix = fix,
            ),
        )
    }

    /**
     * Applies a decision.
     *
     * Show is applied before hide. If a pass is interrupted part-way — the
     * process is killed, the device sleeps — the half that has run is the half
     * that restores access rather than the half that removes it.
     */
    fun apply(decision: EnforcementDecision, bridge: DevicePolicyBridge) {
        // Re-read rather than threaded through from decide(): an unreadable
        // policy must not stop a pass that is otherwise ready to apply, and
        // the VPN pin is the one step that should survive a policy problem.
        val policy = runCatching { FocusPolicy.load(context) }.getOrNull()

        // Re-asserted every pass for the same self-healing reason as the pins
        // below. The geofence is only as good as its input, and a lost FINE
        // grant degrades it silently: coarse location is fuzzed to a ~1-2 km
        // grid, so the phone starts reading home as AWAY with nothing on
        // screen to say why. Background location was previously granted by
        // hand over adb, which a reinstall would have quietly dropped.
        val granted = bridge.grantLocationPermissions()
        bridge.enableLocation()

        // VPN/Private DNS pins + self-uninstall-block re-assertion; see
        // [pinPolicyToDevice].
        pinPolicyToDevice(policy, decision, bridge)

        // Show/hide deltas; see [applyVisibilitySweep]. Show is applied before
        // hide inside it for the same interrupted-pass reason documented there.
        val (hiddenNow, restoredNow) =
            applyVisibilitySweep(decision, bridge, selfPackage = context.packageName)
        rememberEnforcing(decision.isEnforcing)
        // Only recorded when the fence actually returned an answer. A pass
        // with no usable fix must leave the previous verdict standing rather
        // than resetting it to "outside", which would drop hysteresis for the
        // next pass at exactly the moment the input is least reliable.
        decision.insideFence?.let { rememberInsideFence(it) }
        // Durable, in-app-readable record. Logcat is kept for live tailing but
        // cannot be relied on: it rotates, and `run-as` is refused on this
        // build, so logcat alone left the phone unable to explain itself.
        EnforcementLog(context).append(
            EnforcementLog.record(
                timestampMs = System.currentTimeMillis(),
                decision = decision,
                fix = pass?.fix,
                policy = pass?.policy ?: policy,
                homeConfigured = pass?.homeConfigured ?: homeLocationStore.hasHomeLocation(),
                permissions = granted,
                hidDelta = hiddenNow,
                restoredDelta = restoredNow,
            ),
        )
        Log.i(
            FocusDeviceAdminReceiver.TAG,
            "applied ${decision.reason}: hid ${hiddenNow.size}, " +
                "restored ${restoredNow.size}",
        )
    }

    /** Writes the current location as home. See [HomeLocationStore.setHomeToCurrentLocation]. */
    fun setHomeToCurrentLocation(): String? = homeLocationStore.setHomeToCurrentLocation()

    /** Whether home coordinates are provisioned, without revealing them. */
    fun hasHomeLocation(): Boolean = homeLocationStore.hasHomeLocation()

    /** Acquires a fix. See [LocationAcquisition.acquireLocation]. */
    fun acquireLocation(
        timeoutMs: Long = LocationAcquisition.ACQUIRE_TIMEOUT_MS,
        freshWindowMs: Long = LocationAcquisition.FRESH_WINDOW_MS,
        maxAccuracyM: Double? = null,
    ): LocationFix = locationAcquisition.acquireLocation(timeoutMs, freshWindowMs, maxAccuracyM)

    private fun prefs() =
        context.getSharedPreferences("enforcement", Context.MODE_PRIVATE)

    /** Whether the previous pass was enforcing. */
    private fun wasEnforcing(): Boolean = prefs().getBoolean(KEY_ENFORCING, false)

    private fun rememberEnforcing(value: Boolean) =
        prefs().edit().putBoolean(KEY_ENFORCING, value).apply()

    /**
     * Whether the previous pass placed the phone inside the fence.
     *
     * This, not [wasEnforcing], is what hysteresis must key off. Hysteresis
     * exists to stop a phone sitting on the boundary from flapping, so it has
     * to widen the fence only for someone already judged to be inside it.
     */
    private fun wasInsideFence(): Boolean = prefs().getBoolean(KEY_WAS_INSIDE, false)

    private fun rememberInsideFence(value: Boolean) =
        prefs().edit().putBoolean(KEY_WAS_INSIDE, value).apply()

    companion object {
        private const val KEY_ENFORCING = "was_enforcing"

        /** Whether the previous pass placed the phone inside the fence. */
        private const val KEY_WAS_INSIDE = "was_inside_fence"

        /** Longest a pass will wait for a fresh fix before falling back. */
        const val ACQUIRE_TIMEOUT_MS = LocationAcquisition.ACQUIRE_TIMEOUT_MS

        /**
         * A fix at most this old is trusted as describing "now".
         *
         * Deliberately longer than the 15-minute enforcement cadence. A window
         * below the cadence would mark the newest available cache stale on
         * every pass of a phone sitting still, sending every pass to
         * LOCATION_UNKNOWN and blocking everything -- turning the fail-closed
         * default from a safety net into the normal case.
         */
        const val FRESH_WINDOW_MS = LocationAcquisition.FRESH_WINDOW_MS

        /**
         * Picks the fix best able to answer "is the phone inside the fence".
         *
         * Freshness is a HARD GATE and accuracy is a preference *within* it,
         * in that order. Getting this backwards is not a style choice: sorting
         * by accuracy first can surface a very precise fix from this morning,
         * which the age check then rejects, sending the pass to
         * LOCATION_UNKNOWN and blocking everything -- the exact office
         * symptom. A recent coarse fix beats an old precise one because the
         * old one is describing somewhere the phone no longer is.
         *
         * Within the window, accuracy decides: a ±2 km network fix cannot
         * answer a 150 m question, so it loses to a ±10 m GPS fix even if it
         * is a minute newer. Unknown accuracy sorts last rather than first --
         * it might be anything, and this comparison exists to avoid guessing.
         *
         * When nothing is fresh, returns the newest stale fix so the log can
         * report what was actually available; the caller classifies it
         * unusable either way.
         */
        fun best(candidates: List<LocationFix>, freshWindowMs: Long): LocationFix? {
            if (candidates.isEmpty()) return null
            val fresh = candidates.filter { it.ageMs <= freshWindowMs }
            if (fresh.isEmpty()) return candidates.minByOrNull { it.ageMs }
            return fresh.sortedWith(
                compareBy<LocationFix> { it.accuracyM ?: Double.MAX_VALUE }
                    .thenBy { it.ageMs },
            ).first()
        }
    }
}
