package com.livetranslator.live_translator

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel

/**
 * Microphone capture: 16 kHz mono PCM16 streamed to Dart in ~100 ms chunks.
 *
 * Preprocessing (best effort, device-dependent): platform NoiseSuppressor,
 * AcousticEchoCanceler and AutomaticGainControl are attached when available.
 * VOICE_RECOGNITION is used as the source because it gives an unprocessed
 * signal tuned for speech recognition rather than telephony.
 *
 * Events sent to Dart are either a ByteArray (audio) or a map
 * {"event": "stopped", "reason": ...} when capture ends outside Dart's
 * control (notification Stop button, microphone lost to another app).
 */
object AudioCaptureManager : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val effects = mutableListOf<android.media.audiofx.AudioEffect>()

    @Volatile
    private var running = false

    val isRunning: Boolean
        get() = running

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    @Synchronized
    fun start(context: Context, sampleRate: Int) {
        if (running) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("RECORD_AUDIO permission not granted")
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) throw IllegalStateException("Unsupported sample rate: $sampleRate")
        val bufferSize = maxOf(minBuffer * 2, sampleRate * 2) // >= 1 s of headroom

        val audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord.release()
            throw IllegalStateException("Microphone unavailable (in use by another app?)")
        }

        attachEffects(audioRecord.audioSessionId)

        audioRecord.startRecording()
        if (audioRecord.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            releaseRecorder(audioRecord)
            throw IllegalStateException("Could not start recording")
        }

        record = audioRecord
        running = true

        val chunkBytes = sampleRate / 10 * 2 // 100 ms of PCM16
        thread = Thread {
            val chunk = ByteArray(chunkBytes)
            while (running) {
                val read = audioRecord.read(chunk, 0, chunk.size)
                if (read > 0) {
                    val data = chunk.copyOf(read)
                    mainHandler.post { sink?.success(data) }
                } else if (read < 0) {
                    // Microphone was taken away (phone call, another recorder).
                    stopInternal("mic_lost")
                    break
                }
            }
        }.also {
            it.name = "AudioCaptureThread"
            it.start()
        }
    }

    /** Stop initiated from Dart (Stop Listening button) — no event echoed back. */
    @Synchronized
    fun stop() = stopInternal(null)

    /** Stop initiated natively (notification action, mic loss) — Dart is told. */
    @Synchronized
    fun stopWithReason(reason: String) = stopInternal(reason)

    private fun stopInternal(reason: String?) {
        if (!running) return
        running = false
        thread = null
        record?.let { releaseRecorder(it) }
        record = null
        if (reason != null) {
            mainHandler.post {
                sink?.success(mapOf("event" to "stopped", "reason" to reason))
            }
        }
    }

    private fun releaseRecorder(audioRecord: AudioRecord) {
        try {
            audioRecord.stop()
        } catch (_: Exception) {
        }
        audioRecord.release()
        for (effect in effects) {
            try {
                effect.release()
            } catch (_: Exception) {
            }
        }
        effects.clear()
    }

    /**
     * Environmental listening, not a phone call: NoiseSuppressor and
     * AcousticEchoCanceler are tuned for near-field voice chat and strip out
     * exactly the distant/background speech (TV, people across the room) this
     * app must hear — keep them OFF. Only AutomaticGainControl is attached,
     * because it lifts quiet distant speech into a usable range.
     */
    private fun attachEffects(sessionId: Int) {
        try {
            if (AutomaticGainControl.isAvailable()) {
                AutomaticGainControl.create(sessionId)?.let {
                    it.enabled = true
                    effects.add(it)
                }
            }
        } catch (_: Exception) {
            // Effects are best-effort; capture works without them.
        }
    }
}
