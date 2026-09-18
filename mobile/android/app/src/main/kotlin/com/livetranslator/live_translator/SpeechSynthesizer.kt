package com.livetranslator.live_translator

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.EventChannel
import java.util.Locale

/**
 * Reads a finalized translation aloud with the device's own voice
 * (android.speech.tts.TextToSpeech).
 *
 * Emits {"speaking": true/false} so Dart can quiet the microphone uplink while
 * the phone is talking and reopen it the moment speech ends. Nothing here
 * touches capture or the Gemini socket: speaking never interrupts a listening
 * session.
 */
object SpeechSynthesizer : EventChannel.StreamHandler {

    private const val UTTERANCE_ID = "sayvo.translation"

    private var tts: TextToSpeech? = null
    private var ready = false
    private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    /** Speak request that arrived before the engine finished initializing. */
    private var pending: Pair<String, String>? = null

    fun init(context: Context) {
        if (tts != null) return
        tts = TextToSpeech(context.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (!ready) return@TextToSpeech
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = emit(true)
                override fun onDone(utteranceId: String?) = emit(false)
                override fun onStop(utteranceId: String?, interrupted: Boolean) = emit(false)

                @Deprecated("Required by the base class", ReplaceWith(""))
                override fun onError(utteranceId: String?) = emit(false)
                override fun onError(utteranceId: String?, errorCode: Int) = emit(false)
            })
            // A tap that landed during initialization still gets spoken.
            pending?.let { (text, language) ->
                pending = null
                speak(text, language)
            }
        }
    }

    /**
     * Warms the engine and pre-selects the voice for [languageCode]. Android's
     * TextToSpeech binds to its engine service asynchronously, so doing this
     * when a session starts is what keeps the FIRST speaker tap instant.
     */
    fun prepare(languageCode: String) {
        val engine = tts ?: return
        if (!ready) return
        applyLanguage(engine, languageCode)
    }

    /**
     * Speaks [text] with the voice for [languageCode] (BCP-47, e.g. "ar-SA",
     * "pt-BR"). Returns false when no voice is installed for that language, so
     * the UI can say so rather than appearing to do nothing.
     */
    fun speak(text: String, languageCode: String): Boolean {
        val engine = tts ?: return false
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return false
        if (!ready) {
            // Remember it; the init callback above will speak it.
            pending = trimmed to languageCode
            return true
        }
        if (!applyLanguage(engine, languageCode)) return false
        // QUEUE_FLUSH: a new tap replaces what is being said, never queues.
        val result = engine.speak(trimmed, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE_ID)
        return result == TextToSpeech.SUCCESS
    }

    fun stop() {
        tts?.stop()
        emit(false)
    }

    /** Exact locale first ("pt-BR"), then the plain language ("pt"). */
    private fun applyLanguage(engine: TextToSpeech, languageCode: String): Boolean {
        val exact = Locale.forLanguageTag(languageCode)
        if (engine.isLanguageAvailable(exact) >= TextToSpeech.LANG_AVAILABLE) {
            engine.language = exact
            return true
        }
        val primary = Locale.forLanguageTag(languageCode.substringBefore('-'))
        if (engine.isLanguageAvailable(primary) >= TextToSpeech.LANG_AVAILABLE) {
            engine.language = primary
            return true
        }
        return false
    }

    private fun emit(speaking: Boolean) {
        main.post { eventSink?.success(mapOf("speaking" to speaking)) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
