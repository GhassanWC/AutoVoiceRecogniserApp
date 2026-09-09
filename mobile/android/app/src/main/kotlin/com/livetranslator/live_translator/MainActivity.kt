package com.livetranslator.live_translator

import android.os.Build
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Capability probe for native on-device Live Translation. Answers
        // come from the OS APIs on THIS device, never from the version alone.
        // Android needs: on-device SpeechRecognizer (API 31+), audio language
        // detection (API 34+), and ML Kit on-device translation — the Android
        // pipeline ships in an upcoming build, so `supported` stays false
        // here while the capability fields report the real device state.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.livetranslator/capabilities")
            .setMethodCallHandler { call, result ->
                if (call.method != "probe") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val osVersion = "Android ${Build.VERSION.RELEASE}"
                val speechSupported = Build.VERSION.SDK_INT >= 31 &&
                    SpeechRecognizer.isOnDeviceRecognitionAvailable(applicationContext)
                val languageDetectionSupported = speechSupported && Build.VERSION.SDK_INT >= 34
                val updateRequired = Build.VERSION.SDK_INT < 34
                val reason = when {
                    updateRequired ->
                        "Live Translation requires Android 14 or newer for on-device " +
                            "speech with automatic language detection. " +
                            "Your current version is $osVersion."
                    !speechSupported ->
                        "This device has no on-device speech recognition service."
                    else ->
                        "The Android native pipeline (on-device SpeechRecognizer + " +
                            "ML Kit translation) arrives in an upcoming build. " +
                            "Use the Cloud engine on Android until then."
                }
                result.success(
                    mapOf(
                        "supported" to false,
                        "updateRequired" to updateRequired,
                        "reason" to reason,
                        "osVersion" to osVersion,
                        "speechSupported" to speechSupported,
                        "languageDetectionSupported" to languageDetectionSupported,
                        "translationSupported" to false,
                        "availableLanguages" to emptyList<String>(),
                        "missingLanguages" to emptyList<String>(),
                        "translationPairs" to emptyMap<String, String>(),
                    )
                )
            }

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
