# Architecture

## The pipeline

```text
Microphone (native: Android AudioRecord / iOS AVAudioEngine)
    ↓  16 kHz mono PCM16, ~100 ms chunks, platform NS/AEC/AGC where available
Voice Activity Detection (on-device, Dart)          ← silence never leaves the phone
    ↓  speech segments ≈ 0.35–10 s, with 350 ms pre-roll, 800 ms silence hangover
WebSocket  wss://…/live-translation                  ← binary frames + JSON control
    ↓
Backend LiveSession (one per connection)
    ↓  PCM → WAV
Speech recognition provider (auto language detection per segment)
    ↓  { text, language, confidence }
Speaker assignment (heuristic diarization, per session)
    ↓
Translation provider (meaning-focused, small rolling context window)
    ↓
translation event → mobile chat UI (+ optional local history, optional TTS)
```

Latency budget: the segment closes ~0.8 s after the speaker stops (silence
hangover); recognition + translation of a short utterance typically add
1–2 s with real providers, landing inside the 1–3 s product target.

## WebSocket protocol

Text frames are JSON; binary frames carry audio:

```text
[0]      u8      protocol version (1)
[1..36]  ascii   segment id (uuid v4)
[37..40] u32 LE  chunk sequence number within the segment
[41..]   bytes   PCM16LE mono samples
```

Client → server: `session_start {targetLanguage, saveHistory}`,
`segment_start {segmentId, sampleRate, channels, encoding}`, binary audio,
`segment_end {segmentId, durationMs}` (`durationMs: 0` = client VAD discarded
the blip — server drops it without a recognition call), `session_stop`, `ping`.

Server → client: `session_started`, `status {hearing|transcribing|translating}`,
`partial_transcription`, `translation {speakerId, speakerLabel, sourceLanguage,
languageConfidence, originalText, translatedText, …}`, `segment_dropped`,
`limit_reached`, `error {code, message, recoverable}`, `session_ended`, `pong`.

Reliability rules:

- Sequence numbers: duplicates are ignored, gaps drop the segment
  (`audio_gap`) — a half-heard sentence is worse than none.
- Segment ids are client-generated uuids; the server keeps a processed-id set,
  so reconnect retries can never produce duplicate translations.
- The client reconnects with exponential backoff and re-opens the session;
  audio captured while offline is discarded, never uploaded late.
- Heartbeats both ways (app `ping` every 25 s, server WS ping every 30 s).

## Provider abstraction

The backend never hard-codes an AI vendor. Interfaces in `backend/src/providers/`:

| Interface | Implementations | Selected by |
|---|---|---|
| `SpeechRecognitionProvider` | `mock`, `openai` (Whisper), `deepgram` (nova-2, `detect_language`) | `SPEECH_PROVIDER` |
| `TranslationProvider` | `mock`, `openai` (LLM — handles slang & code-switching), `google` (Translation v2) | `TRANSLATION_PROVIDER` |
| `SpeakerDiarizationProvider` | `heuristic`, `none` | `DIARIZATION_PROVIDER` |

The mock pair reproduces the product's example conversation end-to-end with
zero API cost — used for development, tests and `npm run simulate`.

### Speaker detection honesty

V1 diarization is a **heuristic** (language of the segment + time gaps), which
works well precisely in the app's core scenario — multilingual groups — and
degrades to the generic "Speaker" label rather than guessing confidently.
Real voice-print diarization is a Phase-2 provider drop-in behind the same
interface. A wrong speaker label never blocks a translation.

### Language confidence

Every result carries `languageConfidence`. Below 0.5 the app shows
*"Language detected automatically"* instead of a possibly-wrong language name.
When the detected language equals the target language, translation is skipped
(the text is already in the user's language).

## Mobile app structure

```text
lib/
  features/
    onboarding/         language pick + microphone explanation (2 steps, no account)
    live_translation/   main screen, controller (state machine), bubbles, indicator
    history/            saved sessions (opt-in, local, text-only)
    settings/           language, display, privacy, appearance, developer
  services/
    audio/              platform-channel capture + Dart VAD segmenter
    websocket/          reconnecting live-translation client
    auth/               guest-token REST client (keys never in the app)
    permissions/        mic permission wrapper (never loops prompts)
    storage/            settings + history (shared_preferences, JSON)
    tts/                queued text-to-speech ("Speak translations")
    mock/               Demo Mode conversation generator
  models/               messages, sessions, settings, WS events (sync w/ backend)
```

State management is `provider` + `ChangeNotifier` — two controllers
(`SettingsController`, `LiveTranslationController`), no codegen.

### Microphone state machine

`idle → starting → listening → idle`. The invariant enforced by
`LiveTranslationController`: **the UI never claims "Listening" unless native
capture is actually running.** Notification-Stop, mic loss (phone call), OS
killing the background service, and app-resume all resync the state and tell
the user what happened.

### Background listening

- **Android**: a `microphone`-type foreground service
  (`ListeningForegroundService.kt`) with a persistent notification
  ("Live Translator is listening") carrying a **Stop** action. Capture is
  plain `AudioRecord` with NoiseSuppressor/AEC/AGC attached when the device
  provides them. `START_NOT_STICKY` — the OS never restarts listening on its own.
- **iOS**: `AVAudioEngine` with the standard `audio` background mode declared
  in Info.plist. No tricks; the system microphone indicator stays visible.
  Interruptions (calls, Siri) stop the session and inform the UI.

## Backend structure

```text
src/
  modules/
    auth/       guest + email accounts, JWT, scrypt passwords
    users/      profile + preferences (PATCH /user/preferences)
    sessions/   history REST (list, detail, delete one, delete all)
    realtime/   WS server, per-connection LiveSession pipeline, protocol
    usage/      per-user monthly speech-seconds metering & limits
  providers/    speech / translation / diarization adapters (see above)
  storage/      Store interface → MemoryStore (default) or PostgresStore
  middleware/   auth, fixed-window rate limiting, safe error handler
```

Storage is selected by `DATABASE_URL`: unset → in-memory (dev),
set → PostgreSQL (`npm run migrate` applies `storage/schema.sql`).
There is deliberately **no audio column anywhere** — see PRIVACY.md.

## Cost control

- Client VAD: silence is never uploaded, never billed, never metered.
- Client-discarded blips (`durationMs: 0`) skip the recognition call.
- Segments are capped (30 s server-side, 10 s by client segmentation).
- Usage metering counts **processed speech seconds** per user per month
  (`FREE_MONTHLY_MINUTES`, 0 = unlimited) and translated characters.
- REST endpoints are rate-limited per user/IP; the WS closes on message floods.

## MVP phasing

- **Phase 1 (this codebase)**: everything above.
- **Phase 2**: ML diarization provider, Bluetooth mic routing, richer TTS
  (Earphone Mode UI), server-side history sync, accounts UI, subscriptions,
  partial-transcription streaming into the bubbles.
- **Phase 3**: offline models, wearables, summaries.
