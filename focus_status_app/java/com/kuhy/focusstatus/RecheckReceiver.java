package com.kuhy.focusstatus;

import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Fired when the user taps the "Re-check now" notification action.
 * Writes the trigger file the daemon polls; the daemon will break its
 * sleep and perform a fresh location check within ~1 second.
 */
public final class RecheckReceiver extends BroadcastReceiver {
    private static final String TRIGGER = "/data/local/tmp/focus_mode/trigger_recheck";

    @Override
    public void onReceive(Context context, Intent intent) {
        RootShell.run("touch " + TRIGGER + " && chmod 666 " + TRIGGER);
        // Cause an immediate service refresh so the notification reflects
        // the new reading as soon as the daemon writes it.
        Intent refresh = new Intent(context, StatusService.class);
        context.startForegroundService(refresh);

        NotificationManager nm =
                (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) {
            // No separate toast-channel — just nudge the ongoing notif
            // (next tick will show the updated "Last check" timestamp).
            nm.cancel(9999);
        }
    }
}
