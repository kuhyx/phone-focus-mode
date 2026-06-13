package com.kuhy.focusstatus;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Fired when the user taps the demo-curfew action on the status notification.
 * Toggles the curfew FORCE file the daemon + enforcer poll, which makes the
 * full curfew engage immediately regardless of clock or location ("demo"):
 *   - if the force file is absent, create it (and clear any override) -> demo ON;
 *   - if it is present, delete it                                     -> demo OFF.
 * Then writes the recheck trigger so the daemon re-evaluates within ~1s.
 *
 * Lets you experience the real curfew on demand with a one-tap off switch.
 * Safe because the companion app, launcher and keyboard are night-whitelisted,
 * so this notification stays tappable throughout the demo.
 */
public final class CurfewDemoReceiver extends BroadcastReceiver {
    private static final String FORCE =
            "/data/local/tmp/focus_mode/curfew_force_on";
    private static final String OVERRIDE =
            "/data/local/tmp/focus_mode/curfew_override";
    private static final String TRIGGER =
            "/data/local/tmp/focus_mode/trigger_recheck";

    @Override
    public void onReceive(Context context, Intent intent) {
        // Toggle the force file atomically; starting a demo also clears any
        // override (which would otherwise suppress the curfew). Always nudge
        // the daemon afterwards.
        RootShell.run(
                "if [ -e " + FORCE + " ]; then rm -f " + FORCE + "; "
                + "else touch " + FORCE + " && chmod 666 " + FORCE
                + " && rm -f " + OVERRIDE + "; fi; "
                + "touch " + TRIGGER + " && chmod 666 " + TRIGGER);

        Intent refresh = new Intent(context, StatusService.class);
        context.startForegroundService(refresh);
    }
}
