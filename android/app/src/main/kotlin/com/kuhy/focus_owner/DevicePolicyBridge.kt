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

    /** Whether this package is profile owner (a work profile, not the device). */
    fun isProfileOwner(): Boolean = dpm.isProfileOwnerApp(context.packageName)

    /**
     * Hides or unhides a package, the DPM equivalent of `pm disable-user`.
     *
     * This is the mechanism the whole Device Owner design rests on, and unlike
     * `pm suspend` and `pm disable-user` — both measured to be cleared by a
     * reboot on this device — it is expected to persist. That expectation is
     * the thing worth testing before a factory reset is spent on it.
     *
     * Requires device owner or profile owner; returns false when held by
     * neither, rather than throwing.
     */
    fun setApplicationHidden(packageName: String, hidden: Boolean): Boolean {
        if (!isDeviceOwner() && !isProfileOwner()) {
            Log.w(FocusDeviceAdminReceiver.TAG, "not DO/PO; cannot hide $packageName")
            return false
        }
        return runCatching {
            val applied = dpm.setApplicationHidden(admin, packageName, hidden)
            Log.i(FocusDeviceAdminReceiver.TAG, "setApplicationHidden($packageName,$hidden)=$applied")
            applied
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setApplicationHidden failed", error)
            false
        }
    }

    /** Whether a package is currently hidden by this admin. */
    fun isApplicationHidden(packageName: String): Boolean {
        if (!isDeviceOwner() && !isProfileOwner()) return false
        return runCatching { dpm.isApplicationHidden(admin, packageName) }
            .getOrDefault(false)
    }

    /** Whether the admin component is active (a weaker state than ownership). */
    fun isAdminActive(): Boolean = dpm.isAdminActive(admin)

    /**
     * Blocks or unblocks uninstalling this app.
     *
     * Device owner already hides Settings' uninstall button, but `adb uninstall`
     * still works without this, and that path is the soft-brick: removing the
     * app without releasing first strands ownership with no holder, and a
     * factory reset becomes the only exit.
     *
     * Self-targeted deliberately. Blocking uninstall of *other* packages is a
     * separate concern and is not what this protects.
     */
    fun setSelfUninstallBlocked(blocked: Boolean): Boolean {
        if (!isDeviceOwner()) {
            Log.w(FocusDeviceAdminReceiver.TAG, "not DO; cannot change uninstall block")
            return false
        }
        return runCatching {
            dpm.setUninstallBlocked(admin, context.packageName, blocked)
            val applied = dpm.isUninstallBlocked(admin, context.packageName)
            Log.i(FocusDeviceAdminReceiver.TAG, "setUninstallBlocked($blocked) -> $applied")
            applied == blocked
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setUninstallBlocked failed", error)
            false
        }
    }

    /** Whether uninstalling this app is currently blocked. */
    fun isSelfUninstallBlocked(): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching { dpm.isUninstallBlocked(admin, context.packageName) }
            .getOrDefault(false)
    }

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
        "uninstallBlocked" to isSelfUninstallBlocked(),
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
            // Order matters and is not interchangeable: uninstall blocking is a
            // device-owner power, so clearing ownership first would leave the
            // block in place with nothing privileged left to lift it — an app
            // that owns nothing and cannot be removed. Unblock, then release.
            setSelfUninstallBlocked(false)
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
