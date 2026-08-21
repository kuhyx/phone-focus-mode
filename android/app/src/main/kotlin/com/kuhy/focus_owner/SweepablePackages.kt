package com.kuhy.focus_owner

import android.content.Context
import android.content.pm.PackageManager

/**
 * Packages the allowlist sweep considers: every third-party app, plus the
 * system apps the policy names in `blockable_system_packages`.
 *
 * Split out of [EnforcementRunner.decide] to keep that file under the
 * 250-line cap.
 *
 * System apps are default-deny rather than filtered out entirely, because
 * the apps most worth blocking are preinstalled — YouTube ships at
 * `/product/app/YouTube` with `FLAG_SYSTEM`, and so does Chrome — while
 * most of the rest are platform components. Measured on this device: 320
 * system packages, of which 243 match no allowlist entry and no
 * `never_disable_prefix`, including `com.android.cellbroadcastreceiver`
 * (emergency alerts) and `com.android.devicelockcontroller`. Sweeping
 * those under Device Owner risks an unrecoverable phone, so eligibility is
 * opt-in per package.
 *
 * [PackageManager.MATCH_UNINSTALLED_PACKAGES] is required, not optional: a
 * package hidden by `setApplicationHidden` is dropped from the default
 * enumeration entirely, even though it remains `installed=true`. Querying
 * with flags `0` therefore returns a set that can never contain anything
 * this app has already hidden — so [EnforcementDecision.packagesToShow]
 * would come back empty and nothing could ever be unhidden again. Measured
 * on device: after a pass hid three apps, the following pass reported
 * `hid 0, restored 0` and left them hidden permanently.
 */
internal fun sweepablePackages(context: Context, policy: FocusPolicy): Set<String> {
    val pm = context.packageManager
    return pm.getInstalledApplications(PackageManager.MATCH_UNINSTALLED_PACKAGES)
        .filter { info ->
            val isSystem =
                (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            !isSystem || info.packageName in policy.blockableSystemPackages
        }
        .map { it.packageName }
        .toSet()
}
