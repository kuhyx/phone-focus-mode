package com.kuhy.focusstatus;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Fired when the user taps the curfew action on the status notification.
 * Toggles the night-curfew escape-hatch file the daemon + enforcer poll:
 *   - if the override file is absent, create it  -> curfew SUSPENDED;
 *   - if it is present, delete it                -> curfew RE-ARMED.
 * Then writes the recheck trigger so the daemon re-evaluates within ~1s and
 * the app's next refresh reflects the new state.
 *
 * This is the on-device "2am opt-out" (no PC needed). It is intentionally the
 * only easy way to suspend curfew; everything else is locked. The action is
 * shown on the notification only while curfew is active, so it is not a
 * day-time temptation.
 */
public final class CurfewToggleReceiver extends BroadcastReceiver {
    private static final String OVERRIDE =
            "/data/local/tmp/focus_mode/curfew_override";
    private static final String TRIGGER =
            "/data/local/tmp/focus_mode/trigger_recheck";

    @Override
    public void onReceive(Context context, Intent intent) {
        // Toggle atomically in one root shell: if the file exists remove it,
        // else create it world-writable. Always nudge the daemon afterwards.
        RootShell.run(
                "if [ -e " + OVERRIDE + " ]; then rm -f " + OVERRIDE + "; "
                + "else touch " + OVERRIDE + " && chmod 666 " + OVERRIDE + "; fi; "
                + "touch " + TRIGGER + " && chmod 666 " + TRIGGER);

        // Immediate service refresh so the notification flips label/state now.
        Intent refresh = new Intent(context, StatusService.class);
        context.startForegroundService(refresh);
    }
}
