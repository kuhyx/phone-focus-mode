package com.kuhy.focus_owner

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * The location-fix acquisition half of [EnforcementRunner].
 *
 * Split out to keep [EnforcementRunner] under the 250-line cap. Owns getting
 * a [LocationFix] out of [LocationManager] -- preferring a fresh cache,
 * falling back to an active request, then to a stale cache -- while
 * [EnforcementRunner] keeps the decide/apply orchestration and delegates
 * acquisition to an instance of this class.
 */
internal class LocationAcquisition(private val context: Context) {

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
            .let { EnforcementRunner.best(it, freshWindowMs) }
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
        val providers = PROVIDER_PREFERENCE.filter { manager.isProviderEnabled(it) }
        if (providers.isEmpty()) return null
        // Every enabled provider is asked at once and the first real answer
        // wins. Asking only the preferred one (GPS) looked like a fallback
        // chain but was not: indoors GPS never answered within the timeout,
        // fused/network were never consulted, and a user-driven refresh came
        // back as TIMEOUT with the same stale cache it was meant to replace.
        val latch = java.util.concurrent.CountDownLatch(1)
        val holder = java.util.concurrent.atomic.AtomicReference<LocationFix?>()
        val pending = java.util.concurrent.atomic.AtomicInteger(providers.size)
        val signals = providers.map { android.os.CancellationSignal() }
        // The main executor rather than a fresh one per call: the consumer
        // only stores a reference and counts down, so it does no work worth a
        // thread, and creating one per pass leaked ~96 threads a day.
        val executor = androidx.core.content.ContextCompat.getMainExecutor(context)
        providers.forEachIndexed { index, provider ->
            manager.getCurrentLocation(provider, signals[index], executor) { location ->
                val fix = location?.toFix(provider)
                // Release as soon as one provider answers, or once all of
                // them have said "nothing" -- no point sitting out the timeout.
                if ((fix != null && holder.compareAndSet(null, fix)) ||
                    pending.decrementAndGet() == 0
                ) {
                    latch.countDown()
                }
            }
        }
        latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        // Stop providers working on a request nobody is waiting for.
        signals.forEach { runCatching { it.cancel() } }
        return holder.get()
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

    companion object {
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
         * Cache window for a user-driven refresh.
         *
         * The 30-minute window above is a battery trade-off for the alarm
         * cadence. A tap on refresh means "where am I *now*": with the
         * default window the pass handed back the same CACHED_FRESH fix
         * and the card did not move, which read as the button doing
         * nothing. Anything older than a few seconds goes to an active
         * request instead.
         */
        const val REFRESH_FRESH_WINDOW_MS = 10_000L

        /**
         * Providers asked when requesting a fix -- all at once, first answer
         * wins (see [requestCurrentFix]). GPS is the only one accurate enough
         * for a 150 m fence; fused and network at least distinguish "same
         * city" from "10 km away", and answer indoors where GPS does not.
         */
        private val PROVIDER_PREFERENCE = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.FUSED_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
        )
    }
}
