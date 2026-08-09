package com.kuhy.focus_owner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires when a scheduled evaluation is due and hands off to the service.
 *
 * A receiver cannot do the work itself: broadcast receivers get roughly ten
 * seconds and no foreground guarantee, while an enforcement pass queries
 * location and iterates every installed package. It exists only to start the
 * service, which then schedules the following run.
 */
class EnforcementAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EnforcementService.start(context)
    }
}
