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
                    "playbackStart" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                        try {
                            AudioPlaybackManager.start(sampleRate)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("playback_start_failed", e.message, null)
                        }
                    }
                    "playbackChunk" -> {
                        call.argument<ByteArray>("data")?.let { AudioPlaybackManager.enqueue(it) }
                        result.success(null)
                    }
                    "playbackStop" -> {
                        AudioPlaybackManager.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/audio_events")
            .setStreamHandler(AudioCaptureManager)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.livetranslator/playback_events"
        ).setStreamHandler(AudioPlaybackManager)

        // Device text-to-speech: reads a finalized translation aloud on demand.
        SpeechSynthesizer.init(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/tts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val language = call.argument<String>("languageCode") ?: "en"
                        result.success(SpeechSynthesizer.speak(text, language))
                    }
                    "stop" -> {
                        SpeechSynthesizer.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/tts_events")
            .setStreamHandler(SpeechSynthesizer)
    }
}
