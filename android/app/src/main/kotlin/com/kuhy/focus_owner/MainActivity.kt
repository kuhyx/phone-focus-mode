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
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "com.kuhy.focus_owner/device_policy"
    }
}
