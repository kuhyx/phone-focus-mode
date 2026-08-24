package com.kuhy.focus_owner

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.util.Log

/**
 * The location-permission and location-services half of [DevicePolicyBridge].
 *
 * Split out to keep [DevicePolicyBridge] under the 250-line cap. Owns the
 * self-grant-permissions and enable-location DPM calls the geofence pass
 * depends on, while [DevicePolicyBridge] keeps ownership/uninstall/hide/VPN
 * concerns and delegates these calls to an instance of this class.
 */
internal class DevicePolicyLocation(
    private val context: Context,
    private val dpm: DevicePolicyManager,
    private val admin: ComponentName,
    private val isDeviceOwnerOrProfileOwner: () -> Boolean,
    private val isDeviceOwner: () -> Boolean,
) {

    /**
     * Self-grants the location permissions the geofence needs.
     *
     * A device owner can grant its own runtime permissions with no user
     * prompt, which matters here for two reasons. First, FINE is required:
     * COARSE is fuzzed to a ~1-2 km grid on Android 12+, against a 150 m
     * fence, so a coarse-only build misclassifies home as AWAY and restores
     * everything the geofence exists to hide. Second, background location was
     * previously granted by hand over adb, which is invisible state that a
     * reinstall silently loses -- and losing it fails closed, blocking
     * everything with no on-screen explanation.
     *
     * Re-asserted on every pass rather than once at provisioning, matching the
     * VPN and private-DNS pins: the protection then self-heals instead of
     * depending on anyone remembering.
     *
     * @return the permissions that are granted after this call.
     */
    fun grantLocationPermissions(): Set<String> {
        if (!isDeviceOwnerOrProfileOwner()) return emptySet()
        return LOCATION_PERMISSIONS.filterTo(mutableSetOf()) { permission ->
            runCatching {
                dpm.setPermissionGrantState(
                    admin,
                    context.packageName,
                    permission,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
                )
                // Read back rather than trusting the setter: setPermissionGrantState
                // returns false for a permission the platform refuses to
                // auto-grant, and ACCESS_BACKGROUND_LOCATION is exactly the
                // kind of permission that can be refused.
                dpm.getPermissionGrantState(admin, context.packageName, permission) ==
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED
            }.getOrElse { error ->
                Log.w(FocusDeviceAdminReceiver.TAG, "could not grant $permission", error)
                false
            }
        }
    }

    /** Turns location services on, so a fix is obtainable at all. */
    fun enableLocation(): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching {
            dpm.setLocationEnabled(admin, true)
            true
        }.getOrElse { error ->
            // Not fatal: the pass still runs and fails closed without a fix.
            Log.w(FocusDeviceAdminReceiver.TAG, "could not enable location", error)
            false
        }
    }

    private companion object {
        /**
         * Location permissions self-granted every pass.
         *
         * Ordered coarse-then-fine-then-background because that is the order
         * the platform expects them to be escalated in; granting background
         * without a foreground grant in place is refused.
         */
        val LOCATION_PERMISSIONS = listOf(
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.ACCESS_BACKGROUND_LOCATION,
        )
    }
}
