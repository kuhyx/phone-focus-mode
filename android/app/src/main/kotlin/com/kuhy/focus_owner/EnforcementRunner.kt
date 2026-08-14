package com.kuhy.focus_owner

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/**
 * Gathers the inputs for one enforcement pass and applies the result.
 *
 * Split out of [EnforcementService] so the service stays a thin lifecycle
 * wrapper and this part can be reasoned about — and eventually instrumented —
 * on its own.
 */
class EnforcementRunner(private val context: Context) {

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

        val home = readHomeLocation()
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
                installedPackages = sweepablePackages(effective),
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

        // Re-pinned every pass, unconditionally rather than tracking the
        // decision: the network filter is the layer that reaches youtube.com
        // in Firefox, in a webview, and in clients nobody has enumerated, so
        // it must not lift when the geofence says AWAY. DISALLOW_CONFIG_VPN is
        // deliberately NOT applied here -- it is a separate, later step, so a
        // misconfigured VPN stays repairable from the device.
        policy?.alwaysOnVpnPackage?.let { vpn ->
            bridge.setAlwaysOnVpn(vpn, lockdown = policy.vpnLockdown)?.let { failure ->
                Log.w(FocusDeviceAdminReceiver.TAG, "always-on VPN not pinned: $failure")
            }
            // Measured hole: `pm uninstall --user 0` removed the provider
            // while it was pinned, taking the network filter with it and
            // leaving the pin aimed at a package that no longer existed.
            bridge.setPackageUninstallBlocked(vpn, true)
        }

        // Pinned every pass for the same reason as the VPN: this is where the
        // domain rules actually live now, so it must not depend on anyone
        // remembering to set it. DISALLOW_CONFIG_PRIVATE_DNS is applied
        // separately, only once the host is confirmed answering.
        policy?.privateDnsHost?.let { host ->
            bridge.setPrivateDns(host)?.let { failure ->
                Log.w(FocusDeviceAdminReceiver.TAG, "private DNS not pinned: $failure")
            }
        }

        // Re-asserted every pass rather than set once at provisioning time, so
        // the protection self-heals: `adb uninstall` while enforcing is the one
        // route that strands device ownership with no holder, and a factory
        // reset is then the only exit. Tracking the decision means going away
        // from home lifts it, which keeps the app removable in exactly the
        // state where enforcement is already off.
        bridge.setSelfUninstallBlocked(decision.isEnforcing)

        // Named rather than counted, so the log can answer "what changed on
        // the pass that broke it" instead of only "how many".
        val restoredNow = mutableListOf<String>()
        val hiddenNow = mutableListOf<String>()
        for (pkg in decision.packagesToShow) {
            if (bridge.isApplicationHidden(pkg)) {
                if (bridge.setApplicationHidden(pkg, false)) restoredNow.add(pkg)
            }
        }
        for (pkg in decision.packagesToHide) {
            // The exporter injects this package into both allowlists, so the
            // decision layer should never propose it. Kept as a belt-and-braces
            // check because it guards the unrecoverable case: hiding the
            // enforcer takes the escape hatch and the trigger with it, and a
            // policy asset rendered before that fix -- or hand-edited -- would
            // otherwise hide the app on the first enforcing pass.
            if (pkg == context.packageName) continue
            if (!bridge.isApplicationHidden(pkg)) {
                if (bridge.setApplicationHidden(pkg, true)) hiddenNow.add(pkg)
            }
        }
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
                homeConfigured = pass?.homeConfigured ?: hasHomeLocation(),
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

    /**
     * Packages the allowlist sweep considers: every third-party app, plus the
     * system apps the policy names in `blockable_system_packages`.
     *
     * System apps are default-deny rather than filtered out entirely, because
     * the apps most worth blocking are preinstalled — YouTube ships at
     * `/product/app/YouTube` with `FLAG_SYSTEM`, and so does Chrome — while
     * most of the rest are platform components. Measured on this device: 320
     * system packages, of which 243 match no allowlist entry and no
     * `never_disable_prefix`, including `com.android.cellbroadcastreceiver`
     * (emergency alerts) and `com.android.devicelockcontroller`. Sweeping
     * those under Device Owner risks an unrecoverable phone, so eligibility is
     * opt-in per package.
     *
     * [PackageManager.MATCH_UNINSTALLED_PACKAGES] is required, not optional: a
     * package hidden by `setApplicationHidden` is dropped from the default
     * enumeration entirely, even though it remains `installed=true`. Querying
     * with flags `0` therefore returns a set that can never contain anything
     * this app has already hidden — so [EnforcementDecision.packagesToShow]
     * would come back empty and nothing could ever be unhidden again. Measured
     * on device: after a pass hid three apps, the following pass reported
     * `hid 0, restored 0` and left them hidden permanently.
     */
    private fun sweepablePackages(policy: FocusPolicy): Set<String> {
        val pm = context.packageManager
        return pm.getInstalledApplications(PackageManager.MATCH_UNINSTALLED_PACKAGES)
            .filter { info ->
                val isSystem =
                    (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                !isSystem || info.packageName in policy.blockableSystemPackages
            }
            .map { it.packageName }
            .toSet()
    }

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
        val fix = acquireLocation(
            freshWindowMs = SET_HOME_MAX_AGE_MS,
            maxAccuracyM = SET_HOME_MAX_ACCURACY_M,
        )
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
    private fun readHomeLocation(): Pair<Double, Double>? {
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

    /**
     * Acquires a fix, preferring a fresh one over whatever happens to be cached.
     *
     * The old implementation only read [LocationManager.getLastKnownLocation]
     * and took the newest across providers, with no age check and no request
     * of its own. That produced both reported failures: at the office with no
     * navigation app running the cache was empty, so the pass fell through to
     * LOCATION_UNKNOWN and blocked everything; and a cached fix from hours ago
     * would have classified the office as home just as readily.
     *
     * Bounded by [ACQUIRE_TIMEOUT_MS] so a pass can never hang waiting for a
     * fix that is not coming. On expiry it falls back to the cache, tagged so
     * the decision layer and the log can both say the acquisition timed out
     * rather than silently presenting a stale fix as current.
     */
    fun acquireLocation(
        timeoutMs: Long = ACQUIRE_TIMEOUT_MS,
        freshWindowMs: Long = FRESH_WINDOW_MS,
        maxAccuracyM: Double? = null,
    ): LocationFix {
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return LocationFix.unavailable(FixOutcome.NO_PERMISSION)
        val manager = context.getSystemService(LocationManager::class.java)
            ?: return LocationFix.unavailable(FixOutcome.NO_PROVIDER)

        // A recent cached fix is both cheaper and no less accurate than one we
        // would request right now, so it short-circuits acquisition entirely.
        // This is the common case whenever any app has used location lately.
        //
        // The caller's own thresholds are applied HERE, not only after the
        // fact: "Set home" demands a fix under 2 minutes old and accurate to
        // 100 m, and if this returned a 5-minute-old cache regardless, every
        // retry would hand back the identical rejected fix and the button
        // could never succeed until the cache aged out on its own.
        cachedFix(manager, freshWindowMs)
            ?.takeIf { it.ageMs <= freshWindowMs }
            // Unknown accuracy is treated as unacceptable, matching `best`.
            // The alternative reading (0.0, i.e. perfect) would let a fix of
            // unknown precision anchor home, which silently inverts the
            // geofence everywhere and forever.
            ?.takeIf {
                maxAccuracyM == null ||
                    (it.accuracyM ?: Double.MAX_VALUE) <= maxAccuracyM
            }
            ?.let { return it.copy(outcome = FixOutcome.CACHED_FRESH) }

        val active = runCatching { requestCurrentFix(manager, timeoutMs) }
            .getOrElse { error ->
                Log.w(FocusDeviceAdminReceiver.TAG, "location request failed", error)
                null
            }
        // The caller's accuracy bound applies to a freshly requested fix too,
        // not just the cache: a brand-new fix that cannot say where it is to
        // within maxAccuracyM answers the question no better than an old one.
        if (active != null &&
            (maxAccuracyM == null || (active.accuracyM ?: Double.MAX_VALUE) <= maxAccuracyM)
        ) {
            return active.copy(outcome = FixOutcome.ACTIVE_OK)
        }

        // Nothing fresh. Return the stale cache anyway, labelled: the decision
        // layer decides what to do with it, and the log needs to say what was
        // actually available rather than reporting a bare "no fix".
        // Window passed through so `best` takes its no-fresh-candidates branch
        // and reports the NEWEST stale fix. Without it every candidate counts
        // as fresh and the most accurate one wins, which does not change the
        // decision (the caller rejects anything stale either way) but makes
        // the log and the set-home error quote a six-hour-old fix when a
        // forty-minute-old one was available.
        val stale = cachedFix(manager, freshWindowMs)
        return stale?.copy(outcome = FixOutcome.TIMEOUT)
            ?: LocationFix.unavailable(FixOutcome.TIMEOUT)
    }

    /** The newest cached fix across enabled providers, or null. */
    private fun cachedFix(
        manager: LocationManager,
        freshWindowMs: Long = Long.MAX_VALUE,
    ): LocationFix? = try {
        manager.getProviders(true)
            .asSequence()
            .mapNotNull { provider ->
                manager.getLastKnownLocation(provider)?.let { provider to it }
            }
            .map { (provider, location) -> location.toFix(provider) }
            .toList()
            .let { best(it, freshWindowMs) }
    } catch (e: SecurityException) {
        Log.w(FocusDeviceAdminReceiver.TAG, "location denied", e)
        null
    }

    /**
     * Asks the platform for a fix now, blocking up to [timeoutMs].
     *
     * Uses [LocationManager] rather than the fused Play Services client on
     * purpose: a device owner should not depend on Play Services, which is
     * itself inside this app's blast radius.
     *
     * The caller must not be on the main thread -- [EnforcementService] runs
     * the pass on a background executor for exactly this reason.
     */
    private fun requestCurrentFix(manager: LocationManager, timeoutMs: Long): LocationFix? {
        val provider = PROVIDER_PREFERENCE.firstOrNull { manager.isProviderEnabled(it) }
            ?: return null
        val latch = java.util.concurrent.CountDownLatch(1)
        val holder = java.util.concurrent.atomic.AtomicReference<Location?>()
        val signal = android.os.CancellationSignal()
        // The main executor rather than a fresh one per call: the consumer
        // only stores a reference and counts down, so it does no work worth a
        // thread, and creating one per pass leaked ~96 threads a day.
        manager.getCurrentLocation(
            provider,
            signal,
            androidx.core.content.ContextCompat.getMainExecutor(context),
        ) { location ->
            holder.set(location)
            latch.countDown()
        }
        val answered = latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        if (!answered) {
            // Stop the provider working on a request nobody is waiting for.
            runCatching { signal.cancel() }
            return null
        }
        return holder.get()?.toFix(provider)
    }

    /** Converts a platform [Location] into the fix the decision layer sees. */
    private fun Location.toFix(provider: String): LocationFix = LocationFix(
        latitude = latitude,
        longitude = longitude,
        // elapsedRealtimeNanos is monotonic, so a clock change cannot make a
        // fix look fresher than it is.
        ageMs = (android.os.SystemClock.elapsedRealtimeNanos() - elapsedRealtimeNanos) /
            1_000_000L,
        accuracyM = if (hasAccuracy()) accuracy.toDouble() else null,
        provider = provider,
        outcome = FixOutcome.CACHED_FRESH,
    )

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
        const val ACQUIRE_TIMEOUT_MS = 20_000L

        /**
         * A fix at most this old is trusted as describing "now".
         *
         * Deliberately longer than the 15-minute enforcement cadence. A window
         * below the cadence would mark the newest available cache stale on
         * every pass of a phone sitting still, sending every pass to
         * LOCATION_UNKNOWN and blocking everything -- turning the fail-closed
         * default from a safety net into the normal case.
         */
        const val FRESH_WINDOW_MS = 30L * 60L * 1000L

        /**
         * Much tighter than [FRESH_WINDOW_MS], for anchoring home.
         *
         * An enforcement pass tolerates an older fix because it re-runs every
         * 15 minutes and a wrong call self-corrects. Home is written once and
         * silently inverts the geofence everywhere if it is wrong, and there
         * is a user present who can just retry -- so it demands a fresh fix.
         */
        const val SET_HOME_MAX_AGE_MS = 2L * 60L * 1000L

        /** Refuse to anchor home to a fix vaguer than the fence is wide. */
        const val SET_HOME_MAX_ACCURACY_M = 100.0

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

        /**
         * Providers tried in order when requesting a fix.
         *
         * GPS first because it is the only one accurate enough for a 150 m
         * fence; fused and network are fallbacks that at least distinguish
         * "same city" from "10 km away".
         */
        private val PROVIDER_PREFERENCE = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.FUSED_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
        )
    }
}
