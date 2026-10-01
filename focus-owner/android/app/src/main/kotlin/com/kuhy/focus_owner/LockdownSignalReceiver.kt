package com.kuhy.focus_owner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives wake-alarm's lockdown signals -- from a separate, same-signing-key
 * app on this phone -- updates [WorkdayLockdown], logs what changed, and
 * starts an immediate enforcement pass so the change shows at once.
 *
 * Signature-permission protected: only an app signed with the same key can
 * send either action. Anything else being able to lock this phone's apps
 * down, or lift that lock, would be a much bigger problem than this solves.
 */
class LockdownSignalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        val record = when (intent.action) {
            ACTION_LOCKDOWN -> {
                val rawUntil = intent.getStringExtra(EXTRA_UNTIL)
                LockdownEventRecord.change(now, WorkdayLockdown.activate(context, rawUntil), rawUntil)
            }
            // The pass started below is what makes hidden apps reappear: it
            // reads the cleared state and re-shows the full allowed set.
            ACTION_LIFT -> LockdownEventRecord.lift(now, WorkdayLockdown.lift(context))
            else -> return
        }
        EnforcementLog(context).append(record)
        EnforcementService.start(context)
    }

    companion object {
        /** Lock down through the `until` extra (inclusive; today if absent). */
        const val ACTION_LOCKDOWN = "com.kuhy.focus_owner.action.LOCKDOWN_UNTIL_EOD"

        /** Clear any lockdown now. */
        const val ACTION_LIFT = "com.kuhy.focus_owner.action.LIFT_LOCKDOWN"

        /** `yyyy-MM-dd`, inclusive. Missing or invalid means today. */
        const val EXTRA_UNTIL = "until"

        /** Custom signature permission wake-alarm must hold to send either. */
        const val PERMISSION_SIGNAL = "com.kuhy.focus_owner.permission.SIGNAL_LOCKDOWN"
    }
}
