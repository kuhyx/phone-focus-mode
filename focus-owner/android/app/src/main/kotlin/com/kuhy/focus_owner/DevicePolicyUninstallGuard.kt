package com.kuhy.focus_owner

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.util.Log

/**
 * The uninstall-blocking half of [DevicePolicyBridge].
 *
 * Split out to keep [DevicePolicyBridge] under the 250-line cap. Owns the
 * uninstall-block DPM calls for both this app (the soft-brick guard) and an
 * arbitrary package (used for the VPN provider), while [DevicePolicyBridge]
 * keeps ownership/hide/VPN/location concerns and delegates these calls to an
 * instance of this class.
 */
internal class DevicePolicyUninstallGuard(
    private val context: Context,
    private val dpm: DevicePolicyManager,
    private val admin: ComponentName,
    private val isDeviceOwner: () -> Boolean,
) {

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
     * Blocks uninstalling an arbitrary package, used for the VPN provider.
     *
     * Measured hole, not a hypothetical: `pm uninstall --user 0
     * com.celzero.bravedns` succeeded while the VPN was pinned and
     * DISALLOW_CONFIG_VPN was set, and the network filter went down with it.
     * The always-on pin survives in device policy, but it points at a package
     * that is no longer installed.
     */
    fun setPackageUninstallBlocked(packageName: String, blocked: Boolean): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching {
            dpm.setUninstallBlocked(admin, packageName, blocked)
            val applied = dpm.isUninstallBlocked(admin, packageName)
            Log.i(FocusDeviceAdminReceiver.TAG, "uninstallBlocked($packageName)=$applied")
            applied == blocked
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setUninstallBlocked($packageName) failed", error)
            false
        }
    }
}
