package com.kuhy.focus_owner

import android.content.Context
import java.io.File

/**
 * The device-independent focus policy, generated from `config.sh`.
 *
 * Deliberately a second implementation of the Dart model in `lib/policy.dart`
 * rather than a call into it. A background [android.app.Service] has no Flutter
 * engine, and starting one per alarm to answer a pure question would be both
 * slow and a new failure mode at exactly the moment enforcement must be
 * reliable.
 *
 * This side is the one that enforces. The Dart copy is used only to display
 * the policy (allowlist sizes, the curfew window), never to decide anything --
 * a `PolicyParityTest` was cited here for months and did not exist, and the
 * two had drifted apart unnoticed. Keeping the Dart side out of the decision
 * path means a drift can no longer produce a wrong answer, only a stale label.
 */
data class FocusPolicy(
    val home: HomeLocation,
    val allowedPackages: Set<String>,
    val nightAllowedPackages: Set<String>,
    val neverDisablePrefixes: Set<String>,
    /**
     * Prefix-matched day allowlist, for apps shipping as a family of packages.
     *
     * Tachiyomi installs every source as its own apk, so an exact list goes
     * stale the moment a new extension is installed -- which from the phone is
     * indistinguishable from the enforcer being broken. Matched on whole
     * labels like [neverDisablePrefixes], not as a bare string prefix.
     *
     * Weaker than the exact list by construction: it allows packages that do
     * not exist yet, so entries must stay narrow and vendor-specific.
     */
    val allowedPrefixes: Set<String> = emptySet(),
    /** Prefixes that survive the curfew. Subset of [allowedPrefixes]. */
    val nightAllowedPrefixes: Set<String> = emptySet(),
    /**
     * Packages denied during curfew even when a prefix in [nightAllowedPrefixes]
     * would otherwise cover them.
     *
     * A prefix like `com.kuhy` is a blanket night guarantee for a whole vendor
     * namespace; this is the narrow per-app exception that guarantee cannot
     * express on its own. Checked before both [nightAllowedPackages] and the
     * prefix match. Absent from an older asset parses to the empty set, which
     * restores today's behaviour of never overriding the prefix.
     */
    val nightBlockedPackages: Set<String> = emptySet(),
    val workoutUnblockDomains: Set<String>,
    val curfew: CurfewWindow?,
    val launcherPackage: String?,
    /**
     * System apps the sweep may hide, named individually.
     *
     * The sweep is default-deny for `FLAG_SYSTEM` packages, because most of
     * them are platform components: on this device 243 of 320 match no
     * allowlist entry and no prefix, including the emergency-alert receiver.
     * Only packages named here are eligible, and an asset that predates this
     * field parses to the empty set, preserving the old never-touch-system
     * behaviour.
     */
    val blockableSystemPackages: Set<String> = emptySet(),
    /**
     * Packages hidden everywhere, exempt from the geofence.
     *
     * The geofence makes leaving home an off switch, which is what device
     * owner exists to remove. These stay hidden under AWAY, CURFEW, AT_HOME
     * and WORKOUT alike; [EnforcementDecision] never places them in
     * `packagesToShow`.
     */
    val alwaysBlockedPackages: Set<String> = emptySet(),
    /**
     * Package pinned as the always-on VPN, or null when none is configured.
     *
     * The exporter emits this only when the package is also protected from
     * the sweep, so the enforcer can never hide the app it has pinned.
     */
    val alwaysOnVpnPackage: String? = null,
    /**
     * Whether the pinned VPN runs in lockdown mode.
     *
     * Lockdown drops every packet not going through the tunnel, which is what
     * stops "turn the VPN off and browse freely". Defaults false so an asset
     * predating the field cannot silently cut the device off.
     */
    val vpnLockdown: Boolean = false,
    /**
     * Private DNS host to pin, or null to leave the setting alone.
     *
     * The domain rules live on this resolver rather than in the VPN app,
     * because the VPN app's own blocklists can be switched off from inside it
     * and no device owner API can stop that.
     */
    val privateDnsHost: String? = null,
    /**
     * Exact-match allowlist for wake-alarm's workday lockdown, or null when
     * the asset predates it -- in which case the lockdown keeps applying the
     * night list, which is what it did before this tier existed. Never read
     * as "allow nothing": that would hide the dialer for days.
     *
     * No prefix list on purpose. `com.kuhy` would keep every kuhy app visible
     * through a lockdown that exists to take them away.
     */
    val lockdownAllowedPackages: Set<String>? = null,
) {
    /**
     * Whether a package must never be hidden.
     *
     * Prefix-matched on whole labels, so `com.android.providers` covers
     * `com.android.providers.telephony` but not `com.android.providersomething`.
     */
    fun isProtected(packageName: String): Boolean =
        matchesPrefix(packageName, neverDisablePrefixes)

    /** Whether a package may run under the given conditions. */
    fun isAllowed(packageName: String, duringCurfew: Boolean): Boolean =
        isAllowed(packageName, if (duringCurfew) AllowlistTier.NIGHT else AllowlistTier.DAY)

    /**
     * Whether a package may run under [tier].
     *
     * Protected packages and the launcher win in every tier, the lockdown one
     * included, so a lockdown can never take away the home screen or settings.
     */
    fun isAllowed(packageName: String, tier: AllowlistTier): Boolean {
        if (isProtected(packageName)) return true
        if (packageName == launcherPackage) return true
        if (tier == AllowlistTier.LOCKDOWN && lockdownAllowedPackages != null) {
            return packageName in lockdownAllowedPackages
        }
        val duringCurfew = tier != AllowlistTier.DAY
        if (duringCurfew && packageName in nightBlockedPackages) return false
        val allowed = if (duringCurfew) nightAllowedPackages else allowedPackages
        if (packageName in allowed) return true
        val prefixes = if (duringCurfew) nightAllowedPrefixes else allowedPrefixes
        return matchesPrefix(packageName, prefixes)
    }

    /** Whether the curfew is in force at [minutesSinceMidnight]. */
    fun isCurfewActive(minutesSinceMidnight: Int): Boolean =
        curfew?.contains(minutesSinceMidnight) ?: false

    /**
     * Packages released while a workout is in progress.
     *
     * The rooted system expressed this as *domains*, because it enforced with
     * a hosts file. Hiding is coarser: there is no way to unblock youtube.com
     * without unhiding the YouTube app, so the exception becomes packages.
     */
    val workoutExemptPackages: Set<String>
        get() {
            val mapping = mapOf(
                "youtube.com" to listOf(
                    "com.google.android.youtube",
                    "com.google.android.apps.youtube.music",
                ),
            )
            val result = mutableSetOf<String>()
            for ((domain, packages) in mapping) {
                val covered = workoutUnblockDomains.any {
                    it == domain || it.endsWith(".$domain")
                }
                if (covered) result.addAll(packages)
            }
            return result
        }

    companion object {
        /**
         * Whether [packageName] is covered by any entry of [prefixes].
         *
         * Matched on whole labels, so `com.android.providers` covers
         * `com.android.providers.telephony` but not
         * `com.android.providersomething`. Shared by every prefix list so the
         * boundary rule cannot drift between them.
         */
        private fun matchesPrefix(packageName: String, prefixes: Set<String>): Boolean =
            prefixes.any { packageName == it || packageName.startsWith("$it.") }

        /** Reads and parses the policy bundled as an asset. */
        fun load(context: Context, assetName: String = "flutter_assets/assets/policy.json"): FocusPolicy =
            context.assets.open(assetName).bufferedReader().use { parse(it.readText()) }

        /** Reads a policy from a file, for tests and for overrides. */
        fun loadFile(file: File): FocusPolicy = parse(file.readText())

        /** Parses a rendered policy document; see [FocusPolicyParser]. */
        fun parse(text: String): FocusPolicy = FocusPolicyParser.parse(text)
    }
}
