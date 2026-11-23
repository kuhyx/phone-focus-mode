package com.kuhy.focus_owner

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager

/**
 * Whether WakeAlarm is gone from this phone (user 0).
 *
 * WakeAlarm is uninstall-blocked and user-control-disabled every pass, so
 * nothing legitimate removes it except focus-owner's own release flow, during
 * which no pass runs. A removal that gets through anyway is what
 * [UninstallLockdown] punishes.
 *
 * The package name is a constant, not read from the policy asset, so a pass
 * whose policy cannot be parsed still notices.
 */
object WakeAlarmPresence {
    const val PACKAGE = "com.kuhy.wake_alarm_sync"

    /**
     * Missing when the package is unknown ([flags] null) or known with
     * `FLAG_INSTALLED` clear -- what `pm uninstall --user 0` and `-k` leave.
     * A hidden app is installed: hidden lives in the private flags.
     */
    fun isMissing(flags: Int?): Boolean =
        flags == null || flags and ApplicationInfo.FLAG_INSTALLED == 0

    /**
     * [isMissing] over [query], which returns the flags or null when the
     * package is not found. A query that throws counts as present: a false
     * lockdown costs the whole phone for two days, a missed check one pass.
     */
    fun check(query: () -> Int?): Boolean = runCatching { isMissing(query()) }.getOrDefault(false)

    /** Whether WakeAlarm is missing on this device now. */
    fun isMissing(context: Context): Boolean = check {
        try {
            @Suppress("DEPRECATION") // the flags overload is API 33+
            context.packageManager
                .getApplicationInfo(PACKAGE, PackageManager.MATCH_UNINSTALLED_PACKAGES)
                .flags
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }
}
