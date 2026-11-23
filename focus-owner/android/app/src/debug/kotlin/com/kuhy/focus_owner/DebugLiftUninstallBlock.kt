package com.kuhy.focus_owner

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * DEBUG BUILDS ONLY (src/debug): lifts WakeAlarm's uninstall block and its
 * user-control pin once, so the AVD check can `pm uninstall` it and watch the
 * next pass apply the uninstall lockdown. The next pass re-applies both.
 *
 * Not exported; reached as root on the AVD:
 *   adb root && adb shell am broadcast -n com.kuhy.focus_owner/.DebugLiftUninstallBlock
 * A release build (the Pixel) never compiles this file.
 */
class DebugLiftUninstallBlock : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        val admin = ComponentName(context, FocusDeviceAdminReceiver::class.java)
        val pkg = WakeAlarmPresence.PACKAGE
        val kept = dpm.getUserControlDisabledPackages(admin).filter { it != pkg }
        dpm.setUserControlDisabledPackages(admin, kept)
        dpm.setUninstallBlocked(admin, pkg, false)
        Log.w(FocusDeviceAdminReceiver.TAG, "DEBUG lifted uninstall block of $pkg")
    }
}
