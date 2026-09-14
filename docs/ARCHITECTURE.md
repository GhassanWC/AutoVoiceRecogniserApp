# Live Translator — Architecture

Final production architecture (September 2026). This replaces every previous
speech/translation experiment: the Node backend (OpenAI Realtime / Deepgram),
whisper.cpp / WhisperKit, and the VoxLingua107 + Apple Speech/Translation
on-device stack are all **gone** — do not reintroduce them.

## The stack

```
Flutter (mobile/)
    │
    ├── Firebase Authentication   (email/password, Google, Apple)
    ├── Cloud Firestore           (profile, target language, text history)
    ├── Firebase App Check        (Play Integrity / App Attest)
    │
    ▼ small HTTPS callable
Cloud Function createLiveTranslateToken (functions/)
    │  holds GEMINI_API_KEY (Secret Manager) — the app never sees it
    ▼
short-lived, single-use Gemini ephemeral token
(liveConnectConstraints lock the model + translationConfig server-side)
    │
    ▼ direct WebSocket (audio never passes through Firebase)
Gemini Live API — models/gemini-3.5-live-translate-preview
```

The user picks ONLY the language they want translations INTO. There is no
source-language picker anywhere: Gemini detects the spoken language per
utterance and reports it via `inputTranscription.languageCode`.

## Audio pipeline

- **Capture (native, kept from the previous architecture):** environmental
  16 kHz mono PCM16, ~100 ms chunks over the `app.livetranslator/audio` +
  `audio_events` channels. iOS: `AVAudioEngine` in `.measurement` mode,
  voice-processing off, omnidirectional mic (`mobile/ios/Runner/AppDelegate.swift`).
  Android: `AudioRecord` + microphone foreground service
  (`AudioCaptureManager.kt`, `ListeningForegroundService.kt`).
- **Uplink:** `LiveTranslationService` (`mobile/lib/services/gemini/`)
  base64-encodes chunks into `realtimeInput.audio` frames. No local ASR, no
  local language detection, no VAD gating — every audible chunk streams.
  The only local audio math is an RMS level for the waveform animation.
- **Downlink:** `serverContent.inputTranscription` (original text + detected
  language) and `outputTranscription` (translation) stream incrementally into
  ONE chat bubble per utterance; `turnComplete` finalizes it. `modelTurn`
  inline audio (24 kHz PCM16) plays through the native playback channel
  (`playbackStart`/`playbackChunk`/`playbackStop`).
- **Half-duplex gate:** while translated audio is audibly playing (native
  `playback_events` reports `active:true`, +300 ms tail) microphone chunks
  are dropped, so the speaker output can't loop back in as new speech
  (important because `echoTargetLanguage` is true).

## Session lifecycle

`LiveTranslationService` state machine: `idle → connecting → listening ⇄
reconnecting → stopping → idle`, with `error` as a recoverable terminal state.
Reconnects: max 3 attempts (1s/2s/4s), preferring the `sessionResumptionUpdate`
handle on the same token, else ONE fresh token. Quota (`resource-exhausted`)
and auth errors are never retried. `stop()` stops capture FIRST (not one
sample after Stop), then flushes playback, closes the socket.

Changing the target language mid-session restarts the session — the ephemeral
token locks `translationConfig` server-side, by design.

## Data model (Firestore)

```
users/{uid}                        displayName, email, photoUrl,
                                   targetLanguageCode, createdAt, updatedAt
users/{uid}/sessions/{sessionId}   targetLanguageCode, startedAt, endedAt,
                                   messageCount
users/{uid}/sessions/{sessionId}/messages/{messageId}
                                   originalText, translatedText,
                                   sourceLanguageCode, targetLanguageCode,
                                   createdAt (serverTimestamp)
```

Rules (`firestore.rules`): a user can only read/write `users/{their uid}/**`.
Only FINALIZED messages are written (never partial transcripts, never audio);
the session doc is created lazily on the first finalized message. The target
language lives on the profile and is mirrored into SharedPreferences for
instant startup.

## Cost rules

- One token request per listening session (plus at most one on reconnect).
- No Firestore writes for partials; no per-chunk writes of any kind.
- Microphone audio flows ONLY over the direct Gemini WebSocket.
- No paid fallback providers. Quota errors surface as a friendly banner.

## Language catalog

`mobile/lib/utils/languages.dart` (`kTargetLanguages`, `geminiCodeFor`) and
`functions/src/languages.ts` (`ALLOWED_TARGET_LANGUAGES`) are kept in lockstep
— parity is pinned by `mobile/test/languages_test.dart` and
`functions/src/languages.test.ts`. Update both together.

## CI

`codemagic.yaml` (iOS TestFlight): injects `GoogleService-Info.plist` from the
secure env var `GOOGLE_SERVICE_INFO_PLIST_B64`, runs `flutter analyze`,
`flutter test`, the functions typecheck+tests, auto-increments the TestFlight
build number, builds the IPA, and gates the build on the IPA containing **no**
legacy ML models (mlmodelc/ggml/whisper/VoxLingua).
