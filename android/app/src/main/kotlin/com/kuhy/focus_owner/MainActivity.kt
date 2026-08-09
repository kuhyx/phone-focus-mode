package com.kuhy.focus_owner

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = DevicePolicyBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(bridge.status())
                    "releaseDeviceOwner" -> result.success(bridge.releaseDeviceOwner())
                    "setApplicationHidden" -> {
                        val pkg = call.argument<String>("package")
                        val hidden = call.argument<Boolean>("hidden")
                        if (pkg == null || hidden == null) {
                            result.error("bad_args", "package and hidden required", null)
                        } else {
                            result.success(bridge.setApplicationHidden(pkg, hidden))
                        }
                    }
                    "isApplicationHidden" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg == null) {
                            result.error("bad_args", "package required", null)
                        } else {
                            result.success(bridge.isApplicationHidden(pkg))
                        }
                    }
                    "runEnforcementNow" -> {
                        // Also the only way to arm the schedule on a device
                        // that has not rebooted since install: the service
                        // schedules the next run at the end of each pass.
                        EnforcementService.start(applicationContext)
                        result.success(true)
                    }
                    "cancelEnforcement" -> {
                        EnforcementScheduler(applicationContext).cancel()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "com.kuhy.focus_owner/device_policy"
    }
}
