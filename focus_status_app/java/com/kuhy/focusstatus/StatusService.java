package com.kuhy.focusstatus;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

/**
 * Foreground service that keeps a persistent notification showing the
 * current state of the focus-mode daemon on the rooted phone. Re-reads
 * /data/local/tmp/focus_mode/status.json via root shell every ~5s and
 * updates the notification text. Notification carries a "Re-check now"
 * action that broadcasts to RecheckReceiver.
 */
public final class StatusService extends Service {

    private static final String CHANNEL_ID = "focus_status_persistent";
    private static final int NOTIF_ID = 1042;
    private static final long REFRESH_MS = 5_000L;

    private static final String STATUS_FILE = "/data/local/tmp/focus_mode/status.json";
    private static final String DAEMON_PID = "/data/local/tmp/focus_mode/daemon.pid";
    private static final String HOSTS_PID = "/data/local/tmp/focus_mode/hosts_enforcer.pid";
    private static final String DNS_PID = "/data/local/tmp/focus_mode/dns_enforcer.pid";
    private static final String LAUNCHER_PID = "/data/local/tmp/focus_mode/launcher_enforcer.pid";

    private Handler handler;
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, REFRESH_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        handler = new Handler(Looper.getMainLooper());
        ensureChannel();
        startForeground(NOTIF_ID, buildNotification(null));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Immediate refresh so the user's launch / action feels responsive.
        handler.removeCallbacks(tick);
        handler.post(tick);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void refresh() {
        String json = RootShell.run("cat " + STATUS_FILE + " 2>/dev/null");
        Status s = Status.parse(json);
        s.daemonAlive = RootShell.pidAlive(DAEMON_PID);
        s.hostsAlive = RootShell.pidAlive(HOSTS_PID);
        s.dnsAlive = RootShell.pidAlive(DNS_PID);
        s.launcherAlive = RootShell.pidAlive(LAUNCHER_PID);

        NotificationManager nm =
                (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.notify(NOTIF_ID, buildNotification(s));
        }
    }

    private void ensureChannel() {
        NotificationManager nm =
                (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) {
            return;
        }
        NotificationChannel ch = new NotificationChannel(
            CHANNEL_ID, "Focus Mode Status",
            NotificationManager.IMPORTANCE_DEFAULT);
        ch.setDescription("Persistent status of the focus-mode daemon");
        ch.setShowBadge(false);
        ch.setSound(null, null);
        ch.enableVibration(false);
        nm.createNotificationChannel(ch);
    }

    private Notification buildNotification(Status s) {
        String title;
        String summary;
        String big;
        int icon;

        if (s == null) {
            title = "Focus Mode: starting...";
            summary = "Reading status";
            big = "Contacting root daemon\u2026";
            icon = android.R.drawable.ic_menu_compass;
        } else {
            boolean focus = "focus".equals(s.mode);
            title = focus ? "\uD83C\uDFE0 Focus: HOME" : "\u2708 Focus: AWAY";
            if (!s.daemonAlive) {
                title = "\u26A0\uFE0F Focus: DAEMON DOWN";
            }
            String dist = (s.distanceM < 0)
                    ? "?"
                    : (s.distanceM + "m");
            summary = "dist " + dist
                    + " \u00B7 disabled " + s.disabledCount
                    + " \u00B7 " + shortTime(s.lastCheckIso);
            big = buildBigText(s);
            icon = focus
                    ? android.R.drawable.ic_lock_idle_lock
                    : android.R.drawable.ic_menu_mylocation;
        }

        PendingIntent recheck = PendingIntent.getBroadcast(
                this, 0,
                new Intent(this, RecheckReceiver.class)
                        .setAction("com.kuhy.focusstatus.RECHECK"),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(icon)
                .setContentTitle(title)
                .setContentText(summary)
                .setStyle(new Notification.BigTextStyle().bigText(big))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_STATUS)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(new Notification.Action.Builder(
                        android.R.drawable.ic_popup_sync,
                        "Re-check now", recheck).build());
        return b.build();
    }

    private static String buildBigText(Status s) {
        StringBuilder sb = new StringBuilder();
        if ("focus".equals(s.mode)) {
            sb.append("At home \u2014 restrictions active\n");
        } else if ("normal".equals(s.mode)) {
            sb.append("Away from home \u2014 normal mode\n");
        } else {
            sb.append("Mode: ").append(s.mode).append('\n');
        }
        if (s.distanceM >= 0) {
            sb.append("Distance: ").append(s.distanceM).append('m');
            if (s.thresholdM >= 0) {
                sb.append("  (threshold ").append(s.thresholdM).append("m)");
            }
            sb.append('\n');
        }
        if (!s.lat.isEmpty() && !s.lon.isEmpty()) {
            sb.append("GPS: ").append(s.lat).append(", ").append(s.lon).append('\n');
        }
        sb.append("Disabled apps: ").append(s.disabledCount).append('\n');
        sb.append("Last check: ").append(
                s.lastCheckIso.isEmpty() ? "never" : s.lastCheckIso).append('\n');
        sb.append("Daemons: ")
                .append(tag("focus", s.daemonAlive)).append(' ')
                .append(tag("hosts", s.hostsAlive)).append(' ')
                .append(tag("dns", s.dnsAlive)).append(' ')
                .append(tag("launcher", s.launcherAlive));
        return sb.toString();
    }

    private static String tag(String name, boolean ok) {
        return (ok ? "\u2713" : "\u2717") + name;
    }

    private static String shortTime(String iso) {
        // Expect "YYYY-MM-DD HH:MM:SS"; show HH:MM:SS.
        if (iso == null || iso.length() < 19) {
            return iso == null ? "" : iso;
        }
        return iso.substring(11, 19);
    }
}
