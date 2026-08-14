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

    /**
     * The VPN provider whose uninstall this admin has blocked, if any.
     *
     * Read back from the system rather than remembered in the app, so the
     * release path still finds it after a process restart -- an unremovable
     * app left behind by a half-completed release is the failure worth
     * avoiding here.
     */
    private val alwaysOnVpnBlockedPackage: String?
        get() = runCatching { dpm.getAlwaysOnVpnPackage(admin) }.getOrNull()

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
        if (!isDeviceOwner() && !isProfileOwner()) return emptySet()
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

    /**
     * Pins [vpnPackage] as the always-on VPN, the network-level block.
     *
     * This is the DPM call, not `settings put secure always_on_vpn_app` --
     * that one writes successfully, survives a reboot, and does nothing,
     * because VpnManager ignores adb-written values. Measured on this device.
     *
     * [lockdown] drops every packet that is not going through the tunnel,
     * which is what closes "stop the VPN and browse freely". It is a real
     * hazard and not the default: if the VPN app breaks, the device has no
     * connectivity until device ownership is released. That is survivable
     * only because the release path is in the app itself and does not need
     * the network -- verified on this device.
     *
     * @return null on success, or a message describing why it failed.
     */
    fun setAlwaysOnVpn(vpnPackage: String, lockdown: Boolean = false): String? {
        if (!isDeviceOwner()) return "not device owner"
        return runCatching {
            dpm.setAlwaysOnVpnPackage(admin, vpnPackage, lockdown)
            val active = dpm.getAlwaysOnVpnPackage(admin)
            Log.i(FocusDeviceAdminReceiver.TAG, "alwaysOnVpn -> $active")
            if (active == vpnPackage) null else "pinned $active, expected $vpnPackage"
        }.getOrElse { error ->
            // UnsupportedOperationException is the documented signal that the
            // package does not declare a VPN service, or does not opt in to
            // always-on. Report it rather than leaving a silent no-op.
            Log.e(FocusDeviceAdminReceiver.TAG, "setAlwaysOnVpnPackage failed", error)
            error.message ?: error::class.java.simpleName
        }
    }

    /**
     * Pins Private DNS to [host] and forbids the user changing it.
     *
     * This is the layer that survives the bypass measured on 2026-08-11:
     * RethinkDNS's blocklists can be switched off from inside that app in a
     * few taps, and no device owner API can stop it. Private DNS is a system
     * setting, so the rules move to a resolver the phone cannot edit at all.
     *
     * Fails loudly rather than silently: an unresolvable or unreachable host
     * here means no DNS at all, so the caller must verify before locking.
     *
     * @return null on success, or a message describing why it failed.
     */
    fun setPrivateDns(host: String): String? {
        if (!isDeviceOwner()) return "not device owner"
        return runCatching {
            val result = dpm.setGlobalPrivateDnsModeSpecifiedHost(admin, host)
            val active = dpm.getGlobalPrivateDnsHost(admin)
            Log.i(FocusDeviceAdminReceiver.TAG, "privateDns($host) -> code=$result now=$active")
            if (result == DevicePolicyManager.PRIVATE_DNS_SET_NO_ERROR && active == host) {
                null
            } else {
                "setGlobalPrivateDnsModeSpecifiedHost returned $result (host=$active)"
            }
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setPrivateDns failed", error)
            error.message ?: error::class.java.simpleName
        }
    }

    /** The Private DNS host currently pinned, or null. */
    fun privateDnsHost(): String? {
        if (!isDeviceOwner()) return null
        return runCatching { dpm.getGlobalPrivateDnsHost(admin) }.getOrNull()
    }

    /** Blocks or unblocks user changes to Private DNS. */
    fun setPrivateDnsConfigBlocked(blocked: Boolean): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching {
            if (blocked) {
                dpm.addUserRestriction(admin, android.os.UserManager.DISALLOW_CONFIG_PRIVATE_DNS)
            } else {
                dpm.clearUserRestriction(admin, android.os.UserManager.DISALLOW_CONFIG_PRIVATE_DNS)
            }
            Log.i(FocusDeviceAdminReceiver.TAG, "DISALLOW_CONFIG_PRIVATE_DNS=$blocked")
            true
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "DISALLOW_CONFIG_PRIVATE_DNS failed", error)
            false
        }
    }

    /** The package currently pinned as always-on VPN, or null. */
    fun alwaysOnVpnPackage(): String? {
        if (!isDeviceOwner()) return null
        return runCatching { dpm.getAlwaysOnVpnPackage(admin) }.getOrNull()
    }

    /**
     * Prevents the user from changing VPN configuration.
     *
     * Applied separately from [setAlwaysOnVpn] and only after it is confirmed
     * working: pinning the restriction first would make a failed VPN setup
     * harder to repair from the device.
     */
    fun setVpnConfigBlocked(blocked: Boolean): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching {
            if (blocked) {
                dpm.addUserRestriction(admin, android.os.UserManager.DISALLOW_CONFIG_VPN)
            } else {
                dpm.clearUserRestriction(admin, android.os.UserManager.DISALLOW_CONFIG_VPN)
            }
            Log.i(FocusDeviceAdminReceiver.TAG, "DISALLOW_CONFIG_VPN=$blocked")
            true
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "DISALLOW_CONFIG_VPN failed", error)
            false
        }
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
            val vpn = alwaysOnVpnBlockedPackage
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
