package com.kuhy.focus_owner

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
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
        val fix = if (home == null) null else lastKnownLocation()
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
                installedPackages = installedThirdPartyPackages(),
                minutesSinceMidnight = minutes,
                latitude = fix?.first,
                longitude = fix?.second,
                currentlyEnforcing = wasEnforcing(),
                workoutActive = false,
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
        var shown = 0
        var hidden = 0
        for (pkg in decision.packagesToShow) {
            if (bridge.isApplicationHidden(pkg)) {
                if (bridge.setApplicationHidden(pkg, false)) shown++
            }
        }
        for (pkg in decision.packagesToHide) {
            // Defence in depth: the policy already refuses to hide these, but
            // hiding the launcher or the dialer would be unrecoverable from
            // the device itself, so it is checked again at the point of use.
            if (pkg == context.packageName) continue
            if (!bridge.isApplicationHidden(pkg)) {
                if (bridge.setApplicationHidden(pkg, true)) hidden++
            }
        }
        rememberEnforcing(decision.isEnforcing)
        Log.i(
            FocusDeviceAdminReceiver.TAG,
            "applied ${decision.reason}: hid $hidden, restored $shown",
        )
    }

    /** Third-party packages, the only ones the allowlist sweep considers. */
    private fun installedThirdPartyPackages(): Set<String> {
        val pm = context.packageManager
        return pm.getInstalledApplications(0)
            .filter { (it.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) == 0 }
            .map { it.packageName }
            .toSet()
    }

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

    /** The most recent fix, or null when unavailable or not permitted. */
    private fun lastKnownLocation(): Pair<Double, Double>? {
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) return null
        val manager = context.getSystemService(LocationManager::class.java) ?: return null
        return try {
            manager.getProviders(true)
                .asSequence()
                .mapNotNull { manager.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
                ?.let { it.latitude to it.longitude }
        } catch (e: SecurityException) {
            Log.w(FocusDeviceAdminReceiver.TAG, "location denied", e)
            null
        }
    }

    private fun prefs() =
        context.getSharedPreferences("enforcement", Context.MODE_PRIVATE)

    /** Whether the previous pass was enforcing, for geofence hysteresis. */
    private fun wasEnforcing(): Boolean = prefs().getBoolean(KEY_ENFORCING, false)

    private fun rememberEnforcing(value: Boolean) =
        prefs().edit().putBoolean(KEY_ENFORCING, value).apply()

    private companion object {
        const val KEY_ENFORCING = "was_enforcing"
    }
}
