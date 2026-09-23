package com.kuhy.focus_owner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives the "missed a workday alarm" signal from wake-alarm -- a
 * separate, same-signing-key app on this phone -- and starts an immediate
 * enforcement pass under [WorkdayLockdown].
 *
 * Signature-permission protected: only an app signed with the same key can
 * send [ACTION_LOCKDOWN]. Anything else being able to lock this phone's
 * apps down would be a much bigger problem than the one this solves.
 */
class LockdownSignalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_LOCKDOWN) return
        WorkdayLockdown.activate(context)
        EnforcementService.start(context)
    }

    companion object {
        /** Broadcast action wake-alarm's phone_app sends. */
        const val ACTION_LOCKDOWN = "com.kuhy.focus_owner.action.LOCKDOWN_UNTIL_EOD"

        /** Custom signature permission wake-alarm must hold to send it. */
        const val PERMISSION_SIGNAL = "com.kuhy.focus_owner.permission.SIGNAL_LOCKDOWN"
    }
}
