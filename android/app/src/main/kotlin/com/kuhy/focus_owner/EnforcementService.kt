package com.kuhy.focus_owner

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Applies the current enforcement decision, then schedules the next evaluation.
 *
 * Deliberately not a polling loop. Doze can skip a poll indefinitely, and the
 * transitions that matter are known in advance — the curfew boundaries — so
 * [EnforcementScheduler] sets exact alarms for them instead. The service wakes,
 * applies, schedules, and stops; it does not sit resident burning battery to
 * re-decide something that cannot change until a known moment.
 *
 * The unhide path is the one that has to be reliable. Failing to hide an app is
 * a mild disappointment; failing to *unhide* one strands the user without a
 * dialer or a banking app because the phone happened to reboot during curfew.
 * So every run applies the complete allowed set rather than a delta, and a
 * missed run repairs itself on the next one without needing to know what the
 * previous one did.
 */
class EnforcementService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        runCatching { applyAndReschedule() }
            .onFailure { Log.e(FocusDeviceAdminReceiver.TAG, "enforcement run failed", it) }
        // The work is done; the alarm brings us back. START_NOT_STICKY because
        // a restart by the system would be a duplicate of the next alarm.
        stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun applyAndReschedule() {
        val context = applicationContext
        // Scheduled first, in a finally, so that no failure below can end the
        // chain: an enforcement bug should cost one tick, not stop the system.
        try {
            val bridge = DevicePolicyBridge(context)
            if (!bridge.isDeviceOwner() && !bridge.isProfileOwner()) {
                // Not provisioned: there is nothing this build may enforce, and
                // saying so is more useful than failing silently every tick.
                Log.i(FocusDeviceAdminReceiver.TAG, "not DO/PO - no enforcement applied")
                return
            }
            val decision = EnforcementRunner(context).decide()
            if (decision == null) {
                Log.w(FocusDeviceAdminReceiver.TAG, "no decision - policy unreadable")
                return
            }
            EnforcementRunner(context).apply(decision, bridge)
        } finally {
            EnforcementScheduler(context).scheduleNext()
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Focus enforcement",
                    // Low: this notification exists because a foreground
                    // service requires one, not because it needs attention.
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Focus Owner")
            .setContentText("Applying focus policy")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "focus_enforcement"
        private const val NOTIFICATION_ID = 1

        /** Starts one enforcement run. */
        fun start(context: Context) {
            val intent = Intent(context, EnforcementService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Foreground service type, kept next to the manifest declaration. */
        const val FGS_TYPE: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    }
}
