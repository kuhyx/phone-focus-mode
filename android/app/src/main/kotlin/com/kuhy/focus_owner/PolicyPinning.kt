package com.kuhy.focus_owner

import android.util.Log

/**
 * Re-pins the network-lockdown and self-uninstall-block policy onto the
 * device every pass.
 *
 * Split out of [EnforcementRunner.apply] to keep that file under the 250-line
 * cap. Called with the freshly-loaded [policy] (which may be null if it
 * failed to load -- the VPN/DNS pins are skipped in that case, but the
 * self-uninstall-block re-assertion still runs since it depends only on
 * [decision], not on the policy).
 */
internal fun pinPolicyToDevice(
    policy: FocusPolicy?,
    decision: EnforcementDecision,
    bridge: DevicePolicyBridge,
) {
    // Re-pinned every pass, unconditionally rather than tracking the
    // decision: the network filter is the layer that reaches youtube.com
    // in Firefox, in a webview, and in clients nobody has enumerated, so
    // it must not lift when the geofence says AWAY. DISALLOW_CONFIG_VPN is
    // deliberately NOT applied here -- it is a separate, later step, so a
    // misconfigured VPN stays repairable from the device.
    policy?.alwaysOnVpnPackage?.let { vpn ->
        bridge.setAlwaysOnVpn(vpn, lockdown = policy.vpnLockdown)?.let { failure ->
            Log.w(FocusDeviceAdminReceiver.TAG, "always-on VPN not pinned: $failure")
        }
        // Measured hole: `pm uninstall --user 0` removed the provider
        // while it was pinned, taking the network filter with it and
        // leaving the pin aimed at a package that no longer existed.
        bridge.setPackageUninstallBlocked(vpn, true)
    }

    // Pinned every pass for the same reason as the VPN: this is where the
    // domain rules actually live now, so it must not depend on anyone
    // remembering to set it. DISALLOW_CONFIG_PRIVATE_DNS is applied
    // separately, only once the host is confirmed answering.
    policy?.privateDnsHost?.let { host ->
        bridge.setPrivateDns(host)?.let { failure ->
            Log.w(FocusDeviceAdminReceiver.TAG, "private DNS not pinned: $failure")
        }
    }

    // Re-asserted every pass rather than set once at provisioning time, so
    // the protection self-heals: `adb uninstall` while enforcing is the one
    // route that strands device ownership with no holder, and a factory
    // reset is then the only exit. Tracking the decision means going away
    // from home lifts it, which keeps the app removable in exactly the
    // state where enforcement is already off.
    bridge.setSelfUninstallBlocked(decision.isEnforcing)
}

/** The packages actually changed by [applyVisibilitySweep], named not counted. */
internal data class VisibilitySweepResult(
    val hiddenNow: List<String>,
    val restoredNow: List<String>,
)

/**
 * Applies the decision's show/hide deltas to the device.
 *
 * Split out of [EnforcementRunner.apply] to keep that file under the 250-line
 * cap. Show is applied before hide by the caller's ordering of these two
 * loops -- if a pass is interrupted part-way, the half that has run is the
 * half that restores access rather than the half that removes it.
 */
internal fun applyVisibilitySweep(
    decision: EnforcementDecision,
    bridge: DevicePolicyBridge,
    selfPackage: String,
): VisibilitySweepResult {
    val restoredNow = mutableListOf<String>()
    val hiddenNow = mutableListOf<String>()
    for (pkg in decision.packagesToShow) {
        if (bridge.isApplicationHidden(pkg)) {
            if (bridge.setApplicationHidden(pkg, false)) restoredNow.add(pkg)
        }
    }
    for (pkg in decision.packagesToHide) {
        // The exporter injects this package into both allowlists, so the
        // decision layer should never propose it. Kept as a belt-and-braces
        // check because it guards the unrecoverable case: hiding the
        // enforcer takes the escape hatch and the trigger with it, and a
        // policy asset rendered before that fix -- or hand-edited -- would
        // otherwise hide the app on the first enforcing pass.
        if (pkg == selfPackage) continue
        if (!bridge.isApplicationHidden(pkg)) {
            if (bridge.setApplicationHidden(pkg, true)) hiddenNow.add(pkg)
        }
    }
    return VisibilitySweepResult(hiddenNow = hiddenNow, restoredNow = restoredNow)
}
