package com.kuhy.focus_owner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.UserManager
import android.util.Log

/**
 * Re-arms enforcement after a reboot.
 *
 * Two actions, because one is not enough. `BOOT_COMPLETED` does not arrive
 * until the user first unlocks the device — measured on this phone, where the
 * user stayed `RUNNING_LOCKED` for several minutes after a restart with no
 * network and no app able to start. Relying on it alone means enforcement
 * state is frozen at whatever it was before the reboot until someone unlocks.
 *
 * That freeze is safe in one direction and not the other. Apps stay hidden, so
 * nothing leaks — but apps that *should* have been restored stay hidden too, so
 * a reboot during curfew could leave the dialer missing at breakfast.
 * `LOCKED_BOOT_COMPLETED` fires before unlock, so the schedule is re-armed as
 * early as the system allows and the first post-unlock run repairs the rest.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            // MY_PACKAGE_REPLACED for the same reason as the boot actions:
            // installing over the app cancels its pending alarms, so without
            // it the chain stays dead until someone opens the app. It arrives
            // only for this package and only after the install completes.
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                val unlocked = context.getSystemService(UserManager::class.java)
                    ?.isUserUnlocked ?: false
                Log.i(
                    FocusDeviceAdminReceiver.TAG,
                    "boot: ${intent.action} unlocked=$unlocked",
                )
                // Always re-arm the alarm: it is device-encryption safe and
                // cheap. Only run enforcement once storage is readable, since
                // the policy asset and the coordinates live in credential-
                // encrypted storage and are unreadable before unlock.
                EnforcementScheduler(context).scheduleNext()
                if (unlocked) EnforcementService.start(context)
            }
            else -> Log.w(FocusDeviceAdminReceiver.TAG, "unexpected ${intent.action}")
        }
    }
}
