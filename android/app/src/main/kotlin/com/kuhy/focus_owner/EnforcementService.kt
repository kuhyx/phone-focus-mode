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

    /** Single-threaded so overlapping starts queue rather than race. */
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The LOCATION type is what lifts background location throttling for
        // the fix this pass is about to request. It is requested rather than
        // assumed: the platform refuses that type unless a location permission
        // is already held, and this app grants its own permissions *during* a
        // pass -- so the very first pass after a fresh install has none yet.
        // Measured 2026-08-14: passing it unconditionally threw
        // SecurityException and crashed the service on every alarm, which is
        // strictly worse than a throttled fix. Fall back to SPECIAL_USE alone.
        val foreground = startForegroundTyped(FGS_TYPE) ||
            startForegroundTyped(ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        if (!foreground) {
            // Neither type was accepted. Continuing would leave a started
            // service that never called startForeground, which the platform
            // kills with ForegroundServiceDidNotStartInTimeException -- a
            // crash on every alarm, i.e. enforcement silently stops. Bailing
            // out costs one tick instead; the alarm chain is re-armed below.
            Log.e(FocusDeviceAdminReceiver.TAG, "could not enter foreground; skipping pass")
            EnforcementScheduler(applicationContext).scheduleNext()
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // Run off the main thread. The pass now waits up to
        // EnforcementRunner.ACQUIRE_TIMEOUT_MS for a location fix, and
        // blocking the main thread for that long is an ANR. The foreground
        // notification is already showing, so the service is entitled to stay
        // alive for the few seconds this takes.
        worker.execute {
            runCatching { applyAndReschedule() }
                .onFailure {
                    Log.e(FocusDeviceAdminReceiver.TAG, "enforcement run failed", it)
                }
            // Stopped from the completion path, not from onStartCommand: doing
            // it there would tear the service down while the work is in flight.
            stopSelf(startId)
        }
        // The alarm brings us back. START_NOT_STICKY because a restart by the
        // system would be a duplicate of the next alarm.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    /** Enters the foreground with [type], or returns false if refused. */
    private fun startForegroundTyped(type: Int): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(), type)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        true
    }.getOrElse { error ->
        Log.w(FocusDeviceAdminReceiver.TAG, "FGS type $type refused", error)
        false
    }

    private fun applyAndReschedule() {
        val context = applicationContext
        // Genuinely scheduled FIRST, not merely in a finally. A finally covers
        // exceptions but not process death, and the pass now blocks up to
        // ACQUIRE_TIMEOUT_MS waiting for a fix -- a kill inside that window
        // (low memory, force-stop) would lose the alarm chain entirely, with
        // no way back until the app is opened or the phone reboots. Arming up
        // front costs nothing: the next pass re-arms again regardless.
        EnforcementScheduler(context).scheduleNext()
        try {
            val bridge = DevicePolicyBridge(context)
            if (!bridge.isDeviceOwner() && !bridge.isProfileOwner()) {
                // Not provisioned: there is nothing this build may enforce, and
                // saying so is more useful than failing silently every tick.
                Log.i(FocusDeviceAdminReceiver.TAG, "not DO/PO - no enforcement applied")
                recordFailure(context, "not device owner or profile owner")
                return
            }
            // Granted before deciding, not only in apply(). decide() is what
            // reads the location, so granting afterwards left the very first
            // pass after an install with no permission at all -- outcome
            // NO_PERMISSION, reason LOCATION_UNKNOWN, everything hidden for a
            // full cadence. Cheap and idempotent, so it also stays in apply()
            // where it self-heals every pass.
            bridge.grantLocationPermissions()
            bridge.enableLocation()

            // One runner for both calls: it carries the acquired fix and the
            // pass timings from decide() through to the record apply() writes.
            // Constructing a second one silently discarded all of that.
            val runner = EnforcementRunner(context)
            val decision = runner.decide()
            if (decision == null) {
                Log.w(FocusDeviceAdminReceiver.TAG, "no decision - policy unreadable")
                recordFailure(context, "policy unreadable - no decision made")
                return
            }
            runner.apply(decision, bridge)
        } finally {
            // Re-armed, not redundant with the pre-arm above: scheduleNext
            // picks the sooner of the fallback and the next curfew boundary,
            // and the pass itself can take 20 s, so re-running it here lands
            // on the correct boundary rather than one computed before the
            // pass. Re-arming an already-armed alarm just replaces it.
            EnforcementScheduler(context).scheduleNext()
        }
    }

    /** Leaves a trace for a pass that produced no decision. */
    private fun recordFailure(context: Context, failure: String) {
        EnforcementLog(context).append(
            EnforcementLog.failureRecord(System.currentTimeMillis(), failure),
        )
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

        /**
         * Foreground service type, mirroring the manifest declaration.
         *
         * LOCATION is part of it because the pass requests a fix; without that
         * type, background location delivery is throttled hard enough that the
         * request usually times out and the pass fails closed.
         */
        const val FGS_TYPE: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
    }
}
