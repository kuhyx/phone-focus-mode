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

    /** VPN-pinning and Private-DNS-pinning calls; see [DevicePolicyVpnDns]. */
    private val vpnDns: DevicePolicyVpnDns =
        DevicePolicyVpnDns(dpm, admin, isDeviceOwner = ::isDeviceOwner)

    /** Location-permission and location-services calls; see [DevicePolicyLocation]. */
    private val location: DevicePolicyLocation = DevicePolicyLocation(
        context,
        dpm,
        admin,
        isDeviceOwnerOrProfileOwner = { isDeviceOwner() || isProfileOwner() },
        isDeviceOwner = ::isDeviceOwner,
    )

    /** Uninstall-blocking calls; see [DevicePolicyUninstallGuard]. */
    private val uninstallGuard: DevicePolicyUninstallGuard =
        DevicePolicyUninstallGuard(context, dpm, admin, isDeviceOwner = ::isDeviceOwner)

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

    /** Self-grants the location permissions the geofence needs. See [DevicePolicyLocation.grantLocationPermissions]. */
    fun grantLocationPermissions(): Set<String> = location.grantLocationPermissions()

    /** Turns location services on, so a fix is obtainable at all. */
    fun enableLocation(): Boolean = location.enableLocation()

    /** Whether a package is currently hidden by this admin. */
    fun isApplicationHidden(packageName: String): Boolean {
        if (!isDeviceOwner() && !isProfileOwner()) return false
        return runCatching { dpm.isApplicationHidden(admin, packageName) }
            .getOrDefault(false)
    }

    /** Whether the admin component is active (a weaker state than ownership). */
    fun isAdminActive(): Boolean = dpm.isAdminActive(admin)

    /**
     * Whether any account exists, which decides if releasing is reversible.
     *
     * `dpm set-device-owner` refuses to run while the device has accounts, so
     * once one is added, releasing ownership can only be undone by a factory
     * reset. The release dialog says so, and it must say so truthfully rather
     * than assume: during provisioning the count is zero and releasing is
     * cheap, which is exactly when the escape hatch should be exercised.
     */
    fun hasAccounts(): Boolean = runCatching {
        // Measured on device rather than assumed: with GET_ACCOUNTS undeclared
        // this returned 5 accounts while dumpsys reported 6, so the call works
        // without the runtime permission but does not necessarily see every
        // account. Only "any account at all" is needed here, so the visibility
        // gap does not matter -- and a permission prompt would be a heavy
        // price for one warning string.
        android.accounts.AccountManager.get(context)
            .getAccountsByType(null)
            .isNotEmpty()
    }.getOrElse { error ->
        // Fail toward the scarier message: claiming a release is cheap when it
        // is not is the more damaging of the two possible wrong answers.
        Log.w(FocusDeviceAdminReceiver.TAG, "could not read accounts", error)
        true
    }

    /** Blocks or unblocks uninstalling this app. See [DevicePolicyUninstallGuard.setSelfUninstallBlocked]. */
    fun setSelfUninstallBlocked(blocked: Boolean): Boolean =
        uninstallGuard.setSelfUninstallBlocked(blocked)

    /** Whether uninstalling this app is currently blocked. */
    fun isSelfUninstallBlocked(): Boolean = uninstallGuard.isSelfUninstallBlocked()

    /** Blocks uninstalling an arbitrary package. See [DevicePolicyUninstallGuard.setPackageUninstallBlocked]. */
    fun setPackageUninstallBlocked(packageName: String, blocked: Boolean): Boolean =
        uninstallGuard.setPackageUninstallBlocked(packageName, blocked)

    /** Pins [vpnPackage] as the always-on VPN. See [DevicePolicyVpnDns.setAlwaysOnVpn]. */
    fun setAlwaysOnVpn(vpnPackage: String, lockdown: Boolean = false): String? =
        vpnDns.setAlwaysOnVpn(vpnPackage, lockdown)

    /** Pins Private DNS to [host]. See [DevicePolicyVpnDns.setPrivateDns]. */
    fun setPrivateDns(host: String): String? = vpnDns.setPrivateDns(host)

    /** The Private DNS host currently pinned, or null. */
    fun privateDnsHost(): String? = vpnDns.privateDnsHost()

    /** Blocks or unblocks user changes to Private DNS. */
    fun setPrivateDnsConfigBlocked(blocked: Boolean): Boolean =
        vpnDns.setPrivateDnsConfigBlocked(blocked)

    /** The package currently pinned as always-on VPN, or null. */
    fun alwaysOnVpnPackage(): String? = vpnDns.alwaysOnVpnPackage()

    /** Prevents the user from changing VPN configuration. See [DevicePolicyVpnDns.setVpnConfigBlocked]. */
    fun setVpnConfigBlocked(blocked: Boolean): Boolean = vpnDns.setVpnConfigBlocked(blocked)

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
        "alwaysOnVpn" to (alwaysOnVpnPackage() ?: ""),
        "hasAccounts" to hasAccounts(),
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
            // Order matters and is not interchangeable: every one of these is a
            // device-owner power, so clearing ownership first would leave them
            // in place with nothing privileged left to lift them — an app that
            // owns nothing and cannot be removed, and a pinned VPN nobody can
            // reconfigure. Undo the restrictions, then release.
            setSelfUninstallBlocked(false)
            setVpnConfigBlocked(false)
            // Leaving Private DNS pinned to a resolver the user cannot change
            // would outlive the ownership required to unpin it, and if that
            // host ever stops answering the device has no DNS at all.
            setPrivateDnsConfigBlocked(false)
            runCatching { dpm.setGlobalPrivateDnsModeOpportunistic(admin) }
                .onFailure {
                    Log.w(FocusDeviceAdminReceiver.TAG, "could not reset Private DNS", it)
                }
            // Read the pinned package BEFORE unpinning: afterwards the getter
            // returns null and the provider would stay permanently
            // unremovable, which is the exact trap this block exists to avoid.
            val vpn = vpnDns.alwaysOnVpnBlockedPackage
            // Unpinning clears lockdown with it, which is what restores
            // connectivity if the VPN app is the thing that broke.
            runCatching { dpm.setAlwaysOnVpnPackage(admin, null, false) }
                .onFailure {
                    Log.w(FocusDeviceAdminReceiver.TAG, "could not unpin VPN", it)
                }
            vpn?.let { setPackageUninstallBlocked(it, false) }
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
