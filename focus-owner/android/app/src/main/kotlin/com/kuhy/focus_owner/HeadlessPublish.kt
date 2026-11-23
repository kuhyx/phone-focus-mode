package com.kuhy.focus_owner

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the headless Dart `publishNowMain` (`lib/main.dart` →
 * `lib/sync/publish.dart`): it reads the phone's alarm time from the sync,
 * pushes [UninstallEvents]' queue under `devices-e2e/focus-owner/`, and
 * reports back on [CHANNEL]. Pattern: wake-alarm's `HeadlessRingStart`.
 *
 * At most one engine; [TIMEOUT_MS] destroys it regardless, so a hung network
 * call cannot keep a second engine alive. Never throws: a pass must not fail
 * because publishing did.
 */
object HeadlessPublish {
    const val CHANNEL = "com.kuhy.focus_owner/publish"
    private const val ENTRYPOINT = "publishNowMain"
    private const val TIMEOUT_MS = 90_000L

    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null

    /**
     * A start asked for while an engine ran: run once more when it stops.
     * That engine may have read the queue before the new event was added
     * (seen on the AVD: the 08:00 event waited for the next pass).
     */
    private var again: Context? = null

    /** Starts the engine on the main thread unless one is already running. */
    fun start(context: Context) {
        val app = context.applicationContext
        handler.post { startOnMain(app) }
    }

    private fun startOnMain(app: Context) {
        if (engine != null) {
            again = app
            return
        }
        try {
            val created = FlutterEngine(app)
            engine = created
            MethodChannel(created.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "pending" -> result.success(UninstallEvents.pending(app))
                        "done" -> {
                            UninstallEvents.result(
                                app,
                                pushed = call.argument<Boolean>("pushed"),
                                generation = (call.argument<Number>("generation") ?: -1).toLong(),
                                hour = call.argument<Int>("alarm_hour"),
                                minute = call.argument<Int>("alarm_minute"),
                                error = call.argument<String>("error"),
                            )
                            result.success(null)
                            // Posted: destroying an engine inside its own
                            // callback would tear the messenger down under the reply.
                            handler.post { stop("done") }
                        }
                        else -> result.notImplemented()
                    }
                }
            val bundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
            created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, ENTRYPOINT))
            handler.postDelayed({ stop("timeout") }, TIMEOUT_MS)
            Log.i(FocusDeviceAdminReceiver.TAG, "publish engine started")
        } catch (e: RuntimeException) {
            Log.w(FocusDeviceAdminReceiver.TAG, "publish engine failed", e)
            stop("failed")
        }
    }

    private fun stop(reason: String) {
        handler.removeCallbacksAndMessages(null)
        engine?.destroy()
        engine = null
        Log.i(FocusDeviceAdminReceiver.TAG, "publish engine stopped: $reason")
        again?.let { app ->
            again = null
            handler.post { startOnMain(app) }
        }
    }
}
