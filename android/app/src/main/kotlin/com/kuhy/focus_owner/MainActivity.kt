package com.kuhy.focus_owner

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /** For channel calls that block; the platform thread must stay free. */
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = DevicePolicyBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(bridge.status())
                    "releaseDeviceOwner" -> result.success(bridge.releaseDeviceOwner())
                    // Off the platform thread: setting home now waits for a
                    // genuinely fresh fix (up to ACQUIRE_TIMEOUT_MS), and
                    // blocking the main thread for that long is an ANR on the
                    // one button that provisions the geofence.
                    "setHomeToCurrentLocation" -> worker.execute {
                        val outcome = runCatching {
                            EnforcementRunner(applicationContext).setHomeToCurrentLocation()
                        }.getOrElse { it.message ?: it::class.java.simpleName }
                        // The work outlives a shutdown() (it only stops new
                        // submissions), so the activity can be gone by now.
                        // Replying to a dead activity's channel throws, and
                        // the home write has already happened either way.
                        if (!isDestroyed && !isFinishing) {
                            runOnUiThread { result.success(outcome) }
                        }
                    }
                    "hasHomeLocation" ->
                        result.success(
                            EnforcementRunner(applicationContext).hasHomeLocation(),
                        )
                    "setAlwaysOnVpn" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg == null) {
                            result.error("bad_args", "package required", null)
                        } else {
                            // Returns the failure message, or null on success,
                            // so the UI can say why rather than just "failed".
                            result.success(bridge.setAlwaysOnVpn(pkg))
                        }
                    }
                    "setVpnConfigBlocked" -> {
                        val blocked = call.argument<Boolean>("blocked")
                        if (blocked == null) {
                            result.error("bad_args", "blocked required", null)
                        } else {
                            result.success(bridge.setVpnConfigBlocked(blocked))
                        }
                    }
                    "setSelfUninstallBlocked" -> {
                        val blocked = call.argument<Boolean>("blocked")
                        if (blocked == null) {
                            result.error("bad_args", "blocked required", null)
                        } else {
                            result.success(bridge.setSelfUninstallBlocked(blocked))
                        }
                    }
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
                    // Returned as raw JSON strings rather than platform maps:
                    // the channel codec stays trivial and the Dart side owns
                    // one well-defined parse, so the record format and the UI
                    // can be versioned together.
                    "readEnforcementLog" -> {
                        val limit = call.argument<Int>("limit") ?: 200
                        result.success(
                            EnforcementLog(applicationContext).readRecent(limit),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "com.kuhy.focus_owner/device_policy"
    }
}
