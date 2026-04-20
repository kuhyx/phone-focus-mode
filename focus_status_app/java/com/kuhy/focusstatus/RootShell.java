package com.kuhy.focusstatus;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.Locale;

/**
 * Tiny root shell helper. Runs commands via Magisk's `su` binary and
 * returns stdout. All IO is clamped so one misbehaving command cannot
 * stall the notification UI loop indefinitely.
 */
final class RootShell {

    private RootShell() {}

    /** Run a one-shot root command and return its stdout (trimmed). */
    static String run(String cmd) {
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[] { "su", "-c", cmd });
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }
            // Bound wait to avoid ANR when root is denied.
            p.waitFor();
            return sb.toString().trim();
        } catch (IOException | InterruptedException e) {
            return "";
        } finally {
            if (p != null) {
                p.destroy();
            }
        }
    }

    /** Return true if a PID file contains a live process. */
    static boolean pidAlive(String pidFilePath) {
        String out = run(String.format(Locale.US,
                "pid=$(cat %s 2>/dev/null); [ -n \"$pid\" ] && kill -0 \"$pid\" 2>/dev/null && echo yes",
                pidFilePath));
        return "yes".equals(out);
    }
}
