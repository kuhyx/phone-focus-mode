package com.kuhy.focus_owner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * ADB-driveable hook for exercising [DevicePolicyBridge.setApplicationHidden].
 *
 * It exists to answer one question that a factory reset should not be spent
 * guessing at: does DPM app-hiding survive a reboot? Both `pm suspend` and
 * `pm disable-user` were measured to be cleared by one on this device, and the
 * Device Owner design assumes `setApplicationHidden` behaves differently.
 *
 * Driving that from a UI would mean tapping through a screen before and after
 * every reboot; a broadcast can be scripted, so the test is repeatable.
 *
 *   adb shell am broadcast -a com.kuhy.focus_owner.HIDE \
 *       --es package <pkg> --ez hidden true --user <id>
 *
 * It is exported so `am broadcast` can reach it at all — a non-exported
 * receiver silently drops shell broadcasts — but gated behind
 * MANAGE_DEVICE_ADMINS, a signature|privileged permission no third-party app
 * can hold. In practice that means the shell and the system, and nothing else.
 *
 * It applies policy that this build otherwise never applies, which is why it is
 * confined to a test affordance rather than wired into normal startup. Remove
 * it once app-hiding persistence is settled.
 */
class HideTestReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val bridge = DevicePolicyBridge(context.applicationContext)
        val pkg = intent.getStringExtra("package")
        if (pkg == null) {
            Log.w(TAG, "HIDE broadcast with no package extra")
            return
        }
        when (intent.action) {
            ACTION_HIDE -> {
                val hidden = intent.getBooleanExtra("hidden", true)
                val applied = bridge.setApplicationHidden(pkg, hidden)
                Log.i(TAG, "RESULT hide $pkg -> requested=$hidden applied=$applied")
            }
            ACTION_QUERY -> {
                Log.i(TAG, "RESULT query $pkg -> hidden=${bridge.isApplicationHidden(pkg)}")
            }
            else -> Log.w(TAG, "unexpected action ${intent.action}")
        }
    }

    companion object {
        private const val TAG = FocusDeviceAdminReceiver.TAG
        const val ACTION_HIDE = "com.kuhy.focus_owner.HIDE"
        const val ACTION_QUERY = "com.kuhy.focus_owner.QUERY"
    }
}
