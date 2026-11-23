// The enforcement apps are pinned three ways on every pass (2026-11-22,
// after a long-press "Pause app" on WakeAlarm silenced the alarm twice).

package com.kuhy.focus_owner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EnforcementAppGuardTest {
    private class FakeGuard(private val suspended: Set<String>) : AppGuard {
        var userControlDisabled: List<String>? = null
        val pinned = mutableListOf<String>()
        val unsuspendAsked = mutableListOf<String>()

        override fun setUserControlDisabled(packages: List<String>): Boolean {
            userControlDisabled = packages
            return true
        }

        override fun pinNotifications(packageName: String): Boolean {
            pinned += packageName
            return true
        }

        override fun isSuspended(packageName: String): Boolean = packageName in suspended

        override fun unsuspend(packages: List<String>): List<String> {
            unsuspendAsked += packages
            return emptyList()
        }
    }

    private fun policy(extra: String) =
        FocusPolicy.parse(
            """
            {
              "schema_version": 1,
              "home": {"latitude": 52.2297, "longitude": 21.0122, "radius_m": 150.0, "hysteresis_m": 30.0},
              "curfew": null,
              "launcher_package": "com.launcher",
              "allowed_packages": ["com.launcher"],
              "night_allowed_packages": ["com.launcher"],
              "never_disable_prefixes": [],
              "workout_unblock_domains": [],
              "browser_packages": []
              $extra
            }
            """.trimIndent(),
        )

    private val both = """,
        "user_control_disabled_packages": ["com.kuhy.wake_alarm_sync", "com.kuhy.diet_guard_app"],
        "permission_pinned_packages": ["com.kuhy.wake_alarm_sync"]"""

    @Test
    fun `an older asset parses both lists to empty`() {
        val p = policy("")
        assertTrue(p.userControlDisabledPackages.isEmpty())
        assertTrue(p.permissionPinnedPackages.isEmpty())
    }

    @Test
    fun `both lists are parsed`() {
        val p = policy(both)
        assertEquals(
            setOf("com.kuhy.wake_alarm_sync", "com.kuhy.diet_guard_app"),
            p.userControlDisabledPackages,
        )
        assertEquals(setOf("com.kuhy.wake_alarm_sync"), p.permissionPinnedPackages)
    }

    @Test
    fun `a pass disables user control, pins notifications and lifts a suspension`() {
        val guard = FakeGuard(suspended = setOf("com.kuhy.diet_guard_app"))
        val lifted = pinEnforcementApps(policy(both), guard)
        assertEquals(listOf("com.kuhy.diet_guard_app", "com.kuhy.wake_alarm_sync"), guard.userControlDisabled)
        assertEquals(listOf("com.kuhy.wake_alarm_sync"), guard.pinned)
        assertEquals(listOf("com.kuhy.diet_guard_app"), guard.unsuspendAsked)
        assertEquals(listOf("com.kuhy.diet_guard_app"), lifted)
    }

    @Test
    fun `an app the pass hides is left unpinned so Android lets it be hidden`() {
        // Android refuses setApplicationHidden on a user-control-disabled
        // package ("Not hiding protected package"): HabitStack stayed in the
        // drawer through a workday lockdown. Hidden, it cannot be paused anyway.
        val guard = FakeGuard(suspended = setOf("com.kuhy.diet_guard_app"))
        val lifted = pinEnforcementApps(policy(both), guard, hiding = setOf("com.kuhy.diet_guard_app"))
        assertEquals(listOf("com.kuhy.wake_alarm_sync"), guard.userControlDisabled)
        assertTrue(guard.unsuspendAsked.isEmpty())
        assertTrue(lifted.isEmpty())
    }

    @Test
    fun `nothing suspended means no unsuspend call`() {
        val guard = FakeGuard(suspended = emptySet())
        assertTrue(pinEnforcementApps(policy(both), guard).isEmpty())
        assertTrue(guard.unsuspendAsked.isEmpty())
    }

    @Test
    fun `no policy touches nothing`() {
        val guard = FakeGuard(suspended = setOf("x"))
        assertTrue(pinEnforcementApps(null, guard).isEmpty())
        assertEquals(null, guard.userControlDisabled)
    }
}
