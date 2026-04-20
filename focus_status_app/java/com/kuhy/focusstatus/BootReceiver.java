package com.kuhy.focusstatus;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Autostart the StatusService when the device finishes booting so the
 * persistent notification reappears without the user having to launch
 * the app manually. BOOT_COMPLETED is delivered after the user unlocks
 * the phone for the first time (if Direct Boot is enabled we also
 * handle LOCKED_BOOT_COMPLETED to fire earlier).
 */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) {
            return;
        }
        if (!"android.intent.action.BOOT_COMPLETED".equals(action)
                && !"android.intent.action.LOCKED_BOOT_COMPLETED".equals(action)) {
            return;
        }
        context.startForegroundService(new Intent(context, StatusService.class));
    }
}
