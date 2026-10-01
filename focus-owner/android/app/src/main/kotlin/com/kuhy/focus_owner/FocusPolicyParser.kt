package com.kuhy.focus_owner

import org.json.JSONObject

/**
 * Parses the rendered policy document into a [FocusPolicy].
 *
 * Split out of `FocusPolicy.kt` for the 250-line cap; [FocusPolicy.parse]
 * delegates here so no caller changed.
 */
internal object FocusPolicyParser {
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
            allowedPrefixes = json.optionalStringSet("allowed_prefixes"),
            nightAllowedPrefixes = json.optionalStringSet("night_allowed_prefixes"),
            nightBlockedPackages = json.optionalStringSet("night_blocked_packages"),
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
            // Absent (an older asset) stays null, which keeps the night list
            // in force during a lockdown rather than hiding everything.
            lockdownAllowedPackages = if (json.has("lockdown_allowed_packages")) {
                json.stringSet("lockdown_allowed_packages")
            } else {
                null
            },
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
