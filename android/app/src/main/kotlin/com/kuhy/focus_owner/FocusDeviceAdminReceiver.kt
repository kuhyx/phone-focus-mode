package com.kuhy.focus_owner

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Device admin component for focus mode.
 *
 * Deliberately inert: it declares the component so the app *can* be provisioned
 * as device owner, but it applies no user restrictions and hides no packages.
 * Enforcement is added only after the removal path in [DevicePolicyBridge] has
 * been exercised on a real device.
 *
 * The ordering matters and is not stylistic. `dpm remove-active-admin` does not
 * work on a device owner, so the only exit that avoids a factory reset is
 * `clearDeviceOwnerApp()`, callable solely by this package on itself. An app
 * that locks the device down before proving it can let go leaves a soft-brick
 * recoverable only through fastboot — painful on a locked bootloader.
 */
class FocusDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        Log.i(TAG, "Device admin enabled")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        Log.i(TAG, "Device admin disabled")
    }

    companion object {
        const val TAG = "FocusOwner"
    }
}
