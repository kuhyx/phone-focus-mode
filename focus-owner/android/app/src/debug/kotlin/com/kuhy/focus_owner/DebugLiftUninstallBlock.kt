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
 * `--es op hide` / `--es op unhide` instead hides WakeAlarm the way a pass
 * hides apps (the hidden-is-not-missing check); `pm hide` is refused for it.
 * `--es op unpin` drops only the user-control pin, so an uninstall attempt
 * meets the uninstall block alone (DELETE_FAILED_OWNER_BLOCKED).
 * A release build (the Pixel) never compiles this file.
 */
class DebugLiftUninstallBlock : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        val admin = ComponentName(context, FocusDeviceAdminReceiver::class.java)
        val pkg = WakeAlarmPresence.PACKAGE
        when (intent.getStringExtra("op")) {
            "hide", "unhide" -> {
                val hidden = intent.getStringExtra("op") == "hide"
                val ok = dpm.setApplicationHidden(admin, pkg, hidden)
                Log.w(FocusDeviceAdminReceiver.TAG, "DEBUG setApplicationHidden($pkg,$hidden)=$ok")
                return
            }
        }
        val kept = dpm.getUserControlDisabledPackages(admin).filter { it != pkg }
        dpm.setUserControlDisabledPackages(admin, kept)
        if (intent.getStringExtra("op") == "unpin") {
            Log.w(FocusDeviceAdminReceiver.TAG, "DEBUG unpinned $pkg; uninstall block kept")
            return
        }
        dpm.setUninstallBlocked(admin, pkg, false)
        Log.w(FocusDeviceAdminReceiver.TAG, "DEBUG lifted uninstall block of $pkg")
    }
}
