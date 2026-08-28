package com.livetranslator.live_translator

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                        try {
                            AudioCaptureManager.start(applicationContext, sampleRate)
                            ListeningForegroundService.start(this)
                            result.success(null)
                        } catch (e: SecurityException) {
                            result.error("permission_denied", e.message, null)
                        } catch (e: Exception) {
                            result.error("audio_start_failed", e.message, null)
                        }
                    }
                    "stop" -> {
                        AudioCaptureManager.stop()
                        ListeningForegroundService.stop(this)
                        result.success(null)
                    }
                    "isRunning" -> result.success(AudioCaptureManager.isRunning)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/audio_events")
            .setStreamHandler(AudioCaptureManager)
    }
}
