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
                installedPackages = sweepablePackages(effective),
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
        // Re-read rather than threaded through from decide(): an unreadable
        // policy must not stop a pass that is otherwise ready to apply, and
        // the VPN pin is the one step that should survive a policy problem.
        val policy = runCatching { FocusPolicy.load(context) }.getOrNull()

        // Re-pinned every pass, unconditionally rather than tracking the
        // decision: the network filter is the layer that reaches youtube.com
        // in Firefox, in a webview, and in clients nobody has enumerated, so
        // it must not lift when the geofence says AWAY. DISALLOW_CONFIG_VPN is
        // deliberately NOT applied here -- it is a separate, later step, so a
        // misconfigured VPN stays repairable from the device.
        policy?.alwaysOnVpnPackage?.let { vpn ->
            bridge.setAlwaysOnVpn(vpn)?.let { failure ->
                Log.w(FocusDeviceAdminReceiver.TAG, "always-on VPN not pinned: $failure")
            }
        }

        // Re-asserted every pass rather than set once at provisioning time, so
        // the protection self-heals: `adb uninstall` while enforcing is the one
        // route that strands device ownership with no holder, and a factory
        // reset is then the only exit. Tracking the decision means going away
        // from home lifts it, which keeps the app removable in exactly the
        // state where enforcement is already off.
        bridge.setSelfUninstallBlocked(decision.isEnforcing)

        var shown = 0
        var hidden = 0
        for (pkg in decision.packagesToShow) {
            if (bridge.isApplicationHidden(pkg)) {
                if (bridge.setApplicationHidden(pkg, false)) shown++
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
                if (bridge.setApplicationHidden(pkg, true)) hidden++
            }
        }
        rememberEnforcing(decision.isEnforcing)
        Log.i(
            FocusDeviceAdminReceiver.TAG,
            "applied ${decision.reason}: hid $hidden, restored $shown",
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
