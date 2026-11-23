// The uninstall-block lift exists only in src/debug: a release APK (the
// Pixel, deploy_owner.sh) must never be able to lift WakeAlarm's block.

package com.kuhy.focus_owner

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugHookReleaseTest {
    private val src = File("src")

    @Test
    fun `the lift hook is debug-only`() {
        assertTrue(File(src, "debug/kotlin/com/kuhy/focus_owner/DebugLiftUninstallBlock.kt").isFile)
        assertFalse(File(src, "main/AndroidManifest.xml").readText().contains("DebugLiftUninstallBlock"))
        val mainSources = File(src, "main/kotlin").walk().filter { it.isFile }.map { it.readText() }
        assertFalse(mainSources.any { it.contains("DebugLiftUninstallBlock") })
    }
}
