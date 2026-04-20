package com.kuhy.focusstatus;

/**
 * Parsed snapshot of /data/local/tmp/focus_mode/status.json.
 * Minimal hand-rolled JSON reader to avoid pulling in a library.
 */
final class Status {
    String mode = "unknown";
    String lat = "";
    String lon = "";
    long distanceM = -1;
    long thresholdM = -1;
    long radiusM = -1;
    long disabledCount = 0;
    long lastCheckTs = 0;
    String lastCheckIso = "";

    boolean daemonAlive = false;
    boolean hostsAlive = false;
    boolean dnsAlive = false;
    boolean launcherAlive = false;

    /** Extract a JSON string or numeric value by key. Returns "" if missing. */
    static String extract(String json, String key) {
        if (json == null) {
            return "";
        }
        // Match either "key":"value"  or  "key":NUMBER  or  "key":null
        String needle = "\"" + key + "\"";
        int i = json.indexOf(needle);
        if (i < 0) {
            return "";
        }
        int j = json.indexOf(':', i + needle.length());
        if (j < 0) {
            return "";
        }
        int k = j + 1;
        // Skip whitespace
        while (k < json.length() && Character.isWhitespace(json.charAt(k))) {
            k++;
        }
        if (k >= json.length()) {
            return "";
        }
        if (json.charAt(k) == '"') {
            int end = json.indexOf('"', k + 1);
            if (end < 0) {
                return "";
            }
            return json.substring(k + 1, end);
        }
        int end = k;
        while (end < json.length()
                && "0123456789-.nul".indexOf(json.charAt(end)) >= 0) {
            end++;
        }
        String v = json.substring(k, end);
        return "null".equals(v) ? "" : v;
    }

    static Status parse(String json) {
        Status s = new Status();
        if (json == null || json.isEmpty()) {
            return s;
        }
        s.mode = nonEmpty(extract(json, "mode"), "unknown");
        s.lat = extract(json, "lat");
        s.lon = extract(json, "lon");
        s.distanceM = parseLongOr(extract(json, "distance_m"), -1);
        s.thresholdM = parseLongOr(extract(json, "threshold_m"), -1);
        s.radiusM = parseLongOr(extract(json, "radius_m"), -1);
        s.disabledCount = parseLongOr(extract(json, "disabled_count"), 0);
        s.lastCheckTs = parseLongOr(extract(json, "last_check_ts"), 0);
        s.lastCheckIso = extract(json, "last_check_iso");
        return s;
    }

    private static String nonEmpty(String v, String fallback) {
        return (v == null || v.isEmpty()) ? fallback : v;
    }

    private static long parseLongOr(String v, long fallback) {
        if (v == null || v.isEmpty()) {
            return fallback;
        }
        try {
            return Long.parseLong(v);
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }
}
