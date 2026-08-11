package com.kuhy.focus_owner

import android.content.Context
import org.json.JSONObject
import java.io.File

/** Schema version this build understands. */
const val SUPPORTED_SCHEMA_VERSION = 1

/** Thrown when the bundled policy cannot be trusted. */
class PolicyFormatException(message: String) : Exception(message)

/** A nightly window that may wrap midnight (23:00 -> 05:00). */
data class CurfewWindow(val startMinutes: Int, val endMinutes: Int) {
    /**
     * Whether [minutesSinceMidnight] falls inside the window.
     *
     * Wrapping windows are the normal case, so "inside" means at or after the
     * start *or* before the end, not both.
     */
    fun contains(minutesSinceMidnight: Int): Boolean =
        if (startMinutes <= endMinutes) {
            minutesSinceMidnight in startMinutes until endMinutes
        } else {
            minutesSinceMidnight >= startMinutes || minutesSinceMidnight < endMinutes
        }
}

/** The home anchor. Coordinates are null in a redacted policy. */
data class HomeLocation(
    val latitude: Double?,
    val longitude: Double?,
    val radiusM: Double,
    val hysteresisM: Double,
) {
    /**
     * Whether this policy carries real coordinates.
     *
     * The committed asset is redacted, so enforcement must check this rather
     * than treating a missing coordinate as (0, 0) — that would put "home" in
     * the Atlantic and silently disable the gate.
     */
    val hasCoordinates: Boolean get() = latitude != null && longitude != null
}

/**
 * The device-independent focus policy, generated from `config.sh`.
 *
 * Deliberately a second implementation of the Dart model in `lib/policy.dart`
 * rather than a call into it. A background [android.app.Service] has no Flutter
 * engine, and starting one per alarm to answer a pure question would be both
 * slow and a new failure mode at exactly the moment enforcement must be
 * reliable. `PolicyParityTest` pins the two against shared fixtures so they
 * cannot drift.
 */
data class FocusPolicy(
    val home: HomeLocation,
    val allowedPackages: Set<String>,
    val nightAllowedPackages: Set<String>,
    val neverDisablePrefixes: Set<String>,
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
) {
    /**
     * Whether a package must never be hidden.
     *
     * Prefix-matched on whole labels, so `com.android.providers` covers
     * `com.android.providers.telephony` but not `com.android.providersomething`.
     */
    fun isProtected(packageName: String): Boolean = neverDisablePrefixes.any {
        packageName == it || packageName.startsWith("$it.")
    }

    /** Whether a package may run under the given conditions. */
    fun isAllowed(packageName: String, duringCurfew: Boolean): Boolean {
        if (isProtected(packageName)) return true
        if (packageName == launcherPackage) return true
        val allowed = if (duringCurfew) nightAllowedPackages else allowedPackages
        return packageName in allowed
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
        /** Reads and parses the policy bundled as an asset. */
        fun load(context: Context, assetName: String = "flutter_assets/assets/policy.json"): FocusPolicy =
            context.assets.open(assetName).bufferedReader().use { parse(it.readText()) }

        /** Reads a policy from a file, for tests and for overrides. */
        fun loadFile(file: File): FocusPolicy = parse(file.readText())

        /** Parses a rendered policy document. */
        fun parse(text: String): FocusPolicy {
            val json = JSONObject(text)
            val version = json.optInt("schema_version", -1)
            if (version != SUPPORTED_SCHEMA_VERSION) {
                // Accepting a newer schema would mean enforcing a policy this
                // code has misread, and a misread allowlist blocks the dialer.
                throw PolicyFormatException(
                    "unsupported schema_version $version " +
                        "(this build understands $SUPPORTED_SCHEMA_VERSION)",
                )
            }
            val home = json.optJSONObject("home")
                ?: throw PolicyFormatException("missing \"home\" object")
            val curfewJson = json.optJSONObject("curfew")
            return FocusPolicy(
                home = HomeLocation(
                    latitude = if (home.isNull("latitude")) null else home.getDouble("latitude"),
                    longitude = if (home.isNull("longitude")) null else home.getDouble("longitude"),
                    radiusM = home.getDouble("radius_m"),
                    hysteresisM = home.getDouble("hysteresis_m"),
                ),
                allowedPackages = json.stringSet("allowed_packages"),
                nightAllowedPackages = json.stringSet("night_allowed_packages"),
                neverDisablePrefixes = json.stringSet("never_disable_prefixes"),
                workoutUnblockDomains = json.stringSet("workout_unblock_domains"),
                blockableSystemPackages = json.optionalStringSet("blockable_system_packages"),
                alwaysBlockedPackages = json.optionalStringSet("always_blocked_packages"),
                // Empty string means "not configured", which is what the
                // exporter writes when the provider is not sweep-protected.
                alwaysOnVpnPackage = json.optString("always_on_vpn_package")
                    .takeIf { it.isNotEmpty() },
                vpnLockdown = json.optBoolean("vpn_lockdown", false),
                privateDnsHost = json.optString("private_dns_host")
                    .takeIf { it.isNotEmpty() },
                curfew = curfewJson?.let {
                    CurfewWindow(
                        startMinutes = parseHhMm(it.getString("start"), "curfew.start"),
                        endMinutes = parseHhMm(it.getString("end"), "curfew.end"),
                    )
                },
                launcherPackage = if (json.isNull("launcher_package")) {
                    null
                } else {
                    json.getString("launcher_package")
                },
            )
        }

        private fun JSONObject.stringSet(field: String): Set<String> {
            val array = optJSONArray(field)
                ?: throw PolicyFormatException("\"$field\" must be a list")
            return (0 until array.length()).mapTo(mutableSetOf()) { array.getString(it) }
        }

        /**
         * A list that may be absent, read as empty.
         *
         * Used for fields added after assets were already shipped. The strict
         * [stringSet] would throw, and an unparsable policy makes the runner
         * skip the pass entirely — safe, but it silently disables enforcement
         * rather than degrading to the previous behaviour. A present-but-wrong
         * type is still an error, since that is a real mistake.
         */
        private fun JSONObject.optionalStringSet(field: String): Set<String> {
            if (!has(field)) return emptySet()
            return stringSet(field)
        }

        private fun parseHhMm(value: String, field: String): Int {
            val parts = value.split(":")
            val hour = parts.getOrNull(0)?.toIntOrNull()
            val minute = parts.getOrNull(1)?.toIntOrNull()
            if (parts.size != 2 || hour == null || minute == null ||
                hour > 23 || minute > 59 || hour < 0 || minute < 0
            ) {
                throw PolicyFormatException("\"$field\" is not a valid time: \"$value\"")
            }
            return hour * 60 + minute
        }
    }
}
