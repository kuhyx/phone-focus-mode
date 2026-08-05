package com.kuhy.focus_owner

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.util.Log

/**
 * Thin wrapper over [DevicePolicyManager] exposing only what this build needs:
 * reporting provisioning state, and giving up device ownership.
 *
 * No restriction is applied anywhere in this class. Adding enforcement is a
 * later, separate step; see [FocusDeviceAdminReceiver] for why the release path
 * ships and is verified first.
 */
class DevicePolicyBridge(private val context: Context) {

    private val dpm: DevicePolicyManager =
        context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    private val admin: ComponentName =
        ComponentName(context, FocusDeviceAdminReceiver::class.java)

    /** Whether this package currently holds device owner. */
    fun isDeviceOwner(): Boolean = dpm.isDeviceOwnerApp(context.packageName)

    /** Whether the admin component is active (a weaker state than ownership). */
    fun isAdminActive(): Boolean = dpm.isAdminActive(admin)

    /**
     * Describes provisioning state for the UI, so the escape hatch can be found
     * without a PC attached.
     */
    fun status(): Map<String, Any> = mapOf(
        "packageName" to context.packageName,
        "isDeviceOwner" to isDeviceOwner(),
        "isAdminActive" to isAdminActive(),
        "sdkInt" to Build.VERSION.SDK_INT,
        "restrictionsApplied" to false,
    )

    /**
     * Relinquishes device ownership without wiping the device.
     *
     * This is the only exit that preserves user data: `dpm remove-active-admin`
     * refuses to act on a device owner, and a factory reset is the sole
     * alternative — one that `DISALLOW_FACTORY_RESET` could itself remove.
     *
     * [DevicePolicyManager.clearDeviceOwnerApp] is deprecated (API 26) but
     * still functional, and it is callable only by the owning package on
     * itself, which is exactly why this method has to live inside the app.
     *
     * @return true when ownership was released or was never held.
     */
    @Suppress("DEPRECATION")
    fun releaseDeviceOwner(): Boolean {
        if (!isDeviceOwner()) {
            Log.i(FocusDeviceAdminReceiver.TAG, "Not device owner; nothing to release")
            return true
        }
        return runCatching {
            dpm.clearDeviceOwnerApp(context.packageName)
            val released = !isDeviceOwner()
            Log.i(FocusDeviceAdminReceiver.TAG, "clearDeviceOwnerApp -> released=$released")
            released
        }.getOrElse { error ->
            // Never rethrow: the UI button that calls this is the last resort
            // before a factory reset, so it must always render an outcome.
            Log.e(FocusDeviceAdminReceiver.TAG, "clearDeviceOwnerApp failed", error)
            false
        }
    }
}
