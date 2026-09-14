package com.livetranslator.live_translator

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Streamed PCM16 playback for Gemini's translated speech (24 kHz mono).
 *
 * Emits {"active": true/false} on its event channel while queued audio is
 * audibly draining — Dart uses that as ground truth for the half-duplex
 * microphone gate (mic chunks are dropped while the device is speaking, so
 * speaker output can't loop back into the translator).
 */
object AudioPlaybackManager : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var track: AudioTrack? = null
    private var writeThread: HandlerThread? = null
    private var writeHandler: Handler? = null
    private var framesWritten = 0L
    private var active = false

    private val pollDrain = object : Runnable {
        override fun run() {
            val current = track ?: return
            val playing = try {
                current.playbackHeadPosition.toLong() < framesWritten
            } catch (_: Exception) {
                false
            }
            setActive(playing)
            if (track != null) mainHandler.postDelayed(this, 120)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun start(sampleRate: Int) {
        if (track != null) return
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val newTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuffer * 4, 64 * 1024))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        val thread = HandlerThread("gemini-playback").also { it.start() }
        writeThread = thread
        writeHandler = Handler(thread.looper)
        framesWritten = 0
        track = newTrack
        newTrack.play()
        mainHandler.post(pollDrain)
    }

    fun enqueue(bytes: ByteArray) {
        val handler = writeHandler ?: return
        handler.post {
            val current = track ?: return@post
            try {
                var offset = 0
                while (offset < bytes.size) {
                    val written = current.write(
                        bytes, offset, bytes.size - offset, AudioTrack.WRITE_BLOCKING
                    )
                    if (written <= 0) break
                    offset += written
                }
                framesWritten += bytes.size / 2
            } catch (_: Exception) {
                // Track torn down mid-write — playbackStop wins.
            }
        }
    }

    fun stop() {
        val current = track ?: return
        track = null
        writeHandler = null
        writeThread?.quitSafely()
        writeThread = null
        mainHandler.removeCallbacks(pollDrain)
        try {
            current.pause()
            current.flush()
            current.release()
        } catch (_: Exception) {
        }
        framesWritten = 0
        setActive(false)
    }

    private fun setActive(value: Boolean) {
        if (value == active) return
        active = value
        mainHandler.post { eventSink?.success(mapOf("active" to value)) }
    }
}
