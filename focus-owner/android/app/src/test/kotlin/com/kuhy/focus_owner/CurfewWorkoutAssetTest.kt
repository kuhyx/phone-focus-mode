package com.kuhy.focus_owner

import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File

/**
 * Reads the SHIPPED policy asset -- the same bytes bundled into the APK -- and
 * asserts the curfew branch keeps every kuhy-owned app visible.
 */
class CurfewWorkoutAssetTest {
    /**
     * Resolve focus-owner/assets/policy.json by walking up from the test's
     * working directory, which Gradle does not guarantee. Reads the committed
     * source asset rather than build/unit_test_assets/, so a stale staged copy
     * cannot make this pass against bytes the APK never shipped.
     */
    private fun assetFile(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "focus-owner/assets/policy.json")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("focus-owner/assets/policy.json not found")
    }

    private fun policy(): FocusPolicy = FocusPolicy.loadFile(assetFile())

    @Test
    fun workoutAppSurvivesTheCurfew() {
        val p = policy()
        assertTrue("workout_app hidden during curfew", p.isAllowed("com.kuhy.workout_app", true))
        assertTrue("workout_app hidden during day", p.isAllowed("com.kuhy.workout_app", false))
    }

    @Test
    fun futureKuhyAppsSurviveTheCurfew() {
        val p = policy()
        for (pkg in listOf("com.kuhy.not_written_yet", "dev.kuhy.not_written_yet")) {
            assertTrue("$pkg hidden during curfew", p.isAllowed(pkg, true))
            assertTrue("$pkg hidden during day", p.isAllowed(pkg, false))
        }
    }

    @Test
    fun lookalikeVendorStaysBlocked() {
        val p = policy()
        assertFalse(p.isAllowed("com.kuhyevil.spy", false))
        assertFalse(p.isAllowed("com.kuhyevil.spy", true))
    }

    @Test
    fun curfewIsActiveAtTwoAM() {
        // 02:00 -> inside the 23:00-05:00 window, so this pins that the
        // assertions above are really exercising the curfew branch.
        assertTrue(policy().isCurfewActive(2 * 60))
    }
}
