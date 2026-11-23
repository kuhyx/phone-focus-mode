package com.kuhy.focus_owner

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log

/**
 * The device-owner calls that protect the enforcement apps, behind an
 * interface so [pinEnforcementApps] is checkable without a device.
 *
 * Added 2026-11-22: a long-press "Pause app" ("Wstrzymaj aplikację") on
 * WakeAlarm suspended it mid-ring, which silenced the alarm on two mornings.
 */
internal interface AppGuard {
    /** Replaces the user-control-disabled set with exactly [packages]. */
    fun setUserControlDisabled(packages: List<String>): Boolean

    /** Pins the notification permission (and full-screen intent, where allowed) to granted. */
    fun pinNotifications(packageName: String): Boolean

    fun isSuspended(packageName: String): Boolean

    /** Lifts a suspension; returns the packages it could not lift. */
    fun unsuspend(packages: List<String>): List<String>
}

/**
 * Pins the policy's enforcement apps: no Force stop / Clear storage / Pause
 * from Settings, notifications pinned on, and any suspension that got through
 * anyway lifted. Returns the packages it found suspended and lifted.
 *
 * The user-control set is replaced, not added to, so dropping an app from
 * the policy really releases it.
 */
internal fun pinEnforcementApps(
    policy: FocusPolicy?,
    guard: AppGuard,
    hiding: Set<String> = emptySet(),
): List<String> {
    if (policy == null) return emptyList()
    // Android refuses to hide a user-control-disabled package ("Not hiding
    // protected package"), so an enforcement app this pass hides is left out:
    // HabitStack stayed in the drawer through a workday lockdown. A hidden app
    // offers no Pause or Force stop, and its uninstall block stays.
    val pinned = (policy.userControlDisabledPackages - hiding).sorted()
    guard.setUserControlDisabled(pinned)
    for (pkg in policy.permissionPinnedPackages.sorted()) guard.pinNotifications(pkg)
    val suspended = pinned.filter(guard::isSuspended)
    if (suspended.isEmpty()) return emptyList()
    val failed = guard.unsuspend(suspended)
    return suspended - failed.toSet()
}

/** [AppGuard] over [DevicePolicyManager]; every call is a no-op unless device owner. */
internal class DevicePolicyAppGuard(
    private val dpm: DevicePolicyManager,
    private val admin: ComponentName,
    private val isDeviceOwner: () -> Boolean,
) : AppGuard {

    override fun setUserControlDisabled(packages: List<String>): Boolean {
        if (!isDeviceOwner() || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return runCatching {
            dpm.setUserControlDisabledPackages(admin, packages)
            Log.i(FocusDeviceAdminReceiver.TAG, "userControlDisabled=${dpm.getUserControlDisabledPackages(admin)}")
            true
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setUserControlDisabledPackages failed", error)
            false
        }
    }

    override fun pinNotifications(packageName: String): Boolean {
        if (!isDeviceOwner()) return false
        val notifications = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            grant(packageName, Manifest.permission.POST_NOTIFICATIONS)
        // An app-op, not a runtime permission: Android may refuse to pin it,
        // which is why wake_alarm also treats a revoked grant as a bypass.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            grant(packageName, Manifest.permission.USE_FULL_SCREEN_INTENT)
        }
        return notifications
    }

    private fun grant(packageName: String, permission: String): Boolean = runCatching {
        val ok = dpm.setPermissionGrantState(
            admin,
            packageName,
            permission,
            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
        )
        Log.i(FocusDeviceAdminReceiver.TAG, "pin $permission for $packageName -> $ok")
        ok
    }.getOrElse { error ->
        Log.w(FocusDeviceAdminReceiver.TAG, "pin $permission for $packageName failed: $error")
        false
    }

    override fun isSuspended(packageName: String): Boolean {
        if (!isDeviceOwner()) return false
        return runCatching { dpm.isPackageSuspended(admin, packageName) }
            .getOrElse { error ->
                // NameNotFoundException: not installed, so nothing to lift.
                if (error !is PackageManager.NameNotFoundException) {
                    Log.w(FocusDeviceAdminReceiver.TAG, "isPackageSuspended($packageName): $error")
                }
                false
            }
    }

    override fun unsuspend(packages: List<String>): List<String> {
        if (!isDeviceOwner()) return packages
        return runCatching {
            val failed = dpm.setPackagesSuspended(admin, packages.toTypedArray(), false).toList()
            // A suspension set by another app (Wellbeing, the shell) may not
            // be the owner's to lift; read back rather than trust the return.
            val still = packages.filter { isSuspended(it) }
            Log.i(FocusDeviceAdminReceiver.TAG, "unsuspend $packages -> failed=$failed still=$still")
            (failed + still).distinct()
        }.getOrElse { error ->
            Log.e(FocusDeviceAdminReceiver.TAG, "setPackagesSuspended(false) failed", error)
            packages
        }
    }
}
