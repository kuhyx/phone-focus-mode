package com.kuhy.focus_owner

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.util.Log

/**
 * The always-on-VPN and Private DNS pinning half of [DevicePolicyBridge].
 *
 * Split out to keep [DevicePolicyBridge] under the 250-line cap. Owns the
 * network-lockdown DPM calls specifically -- pinning the VPN provider,
 * pinning Private DNS, and blocking user changes to either -- while
 * [DevicePolicyBridge] keeps ownership/uninstall/hide concerns and delegates
 * these calls to an instance of this class.
 */
internal class DevicePolicyVpnDns(
    private val dpm: DevicePolicyManager,
    private val admin: ComponentName,
    private val isDeviceOwner: () -> Boolean,
) {

    /**
     * The VPN provider whose uninstall this admin has blocked, if any.
     *
     * Read back from the system rather than remembered in the app, so the
     * release path still finds it after a process restart -- an unremovable
     * app left behind by a half-completed release is the failure worth
     * avoiding here.
     */
    val alwaysOnVpnBlockedPackage: String?
        get() = runCatching { dpm.getAlwaysOnVpnPackage(admin) }.getOrNull()

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
}
