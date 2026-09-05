# Architecture

## The pipeline

```text
Environmental microphone (native: Android AudioRecord / iOS AVAudioEngine,
                          iOS: .measurement mode, voice-processing DSP off)
    ↓  16 kHz mono PCM16, ~100 ms chunks
Adaptive Voice Activity Detection (on-device, Dart)  ← silence never leaves the phone
    ↓  speech segments, adaptive noise-floor threshold,
    ↓  1.5 s pre-roll, 900 ms silence hangover, 15 s cap
WebSocket  wss://…/live-translation                  ← binary frames + JSON control
    ↓
Backend LiveSession (one per connection)
    ↓  audio forwarded as it arrives
Deepgram live stream (one per session: nova-3, language=multi, diarize_model=latest)
    ↓  { text, per-word language, per-word speaker, confidences }
    ↓  speaker ids from the provider, preserved verbatim
transcript_final event → mobile chat UI shows the message with "Translating…"
    ↓
translation queue (concurrency 2, retries w/ backoff on 408/429/5xx/network)
    ↓  OpenAI translation — ALWAYS runs on a non-empty transcript,
    ↓  even when sourceLanguage is "und" (language is metadata only)
translation_complete / translation_failed → updates the SAME message
                                            (+ optional local history, TTS)
```

Reliability rules for translation:

- The speech stream never waits on OpenAI: transcripts flow continuously into
  the queue while earlier utterances are still translating.
- A transcript is never lost because translation failed: it is on screen from
  the moment STT finalizes, and a failed translation shows
  "Translation failed · Retry" — the Retry resubmits the same text over the
  socket (`retry_translation`), no audio is re-recorded.
- Transient failures (network errors, timeouts, HTTP 408/429/5xx) retry with
  ~300 ms → 1 s → 2 s backoff before the user sees anything; permanent errors
  (bad API key) fail immediately and loudly in the logs.
- Every utterance has a stable `messageId`; retries and reconnect-duplicates
  update the existing message, never create a second bubble.
- Startup refuses to run a real provider without its API key — the backend
  never silently degrades to mock.

The Deepgram stream lives for the whole session, so switching languages
mid-conversation needs no reconnect or reconfiguration, and diarized speaker
ids stay stable across the conversation. Client segment ends send a
`Finalize` to flush results immediately; `KeepAlive` frames cover the silent
stretches (silence still never leaves the phone).

**Provider limitation, kept explicit:** nova-3 `language=multi` currently
code-switches between English, Spanish, French, German, Hindi, Russian,
Portuguese, Japanese, Italian and Dutch only (`NOVA3_MULTI_LANGUAGES` in
`deepgram_stream.ts`). A word tagged outside that set yields
`sourceLanguage: "und"` rather than an unverifiable language claim; the
transcript and translation still go through. Expand the list only when
Deepgram's documentation does.

Providers without a streaming mode (openai/mock) fall back to the previous
per-segment batch pipeline (PCM → WAV → transcribe → heuristic speakers), and
the live pipeline also falls back to it if the stream errors mid-session.

Latency budget: the segment closes ~0.9 s after the speaker stops (silence
hangover); recognition + translation of a short utterance typically add
1–2 s with real providers, landing inside the 1–3 s product target.

### Environmental capture, not a phone call

The microphone path is tuned to hear the room, not just the phone's owner:

- iOS: `.playAndRecord` + `.measurement` (no system voice DSP), voice-processing
  I/O explicitly disabled, built-in mic preferred with an omnidirectional polar
  pattern, input gain maxed (there is no AGC in measurement mode), and
  `.allowBluetoothA2DP` only — a Bluetooth headset's narrow-band call mic never
  replaces the environmental microphone.
- VAD: the threshold adapts to the measured noise floor instead of assuming
  near-field levels. Steady noise (A/C hum) raises the floor and never
  triggers; speech above the floor — 30 cm or 4 m away, or a TV at normal
  volume — opens a segment. While sound is above the threshold the floor only
  rises glacially, so hours of TV can never be re-learned as "noise".
  Developer mode (Settings → Developer → Diagnostics Logging) logs RMS, noise
  floor, current threshold, speech flag and segment start/end per chunk.

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
| `StreamingSpeechProvider` | `deepgram` (live WS: nova-3, `language=multi`, `diarize_model=latest`) | `SPEECH_PROVIDER` |
| `SpeechRecognitionProvider` (batch fallback) | `mock`, `openai` (Whisper), `deepgram` (pre-recorded, `detect_language`) | `SPEECH_PROVIDER` |
| `TranslationProvider` | `mock`, `openai` (LLM — handles slang & code-switching), `google` (Translation v2) | `TRANSLATION_PROVIDER` |
| `SpeakerDiarizationProvider` (batch fallback only) | `heuristic`, `none` | `DIARIZATION_PROVIDER` |

The mock pair reproduces the product's example conversation end-to-end with
zero API cost — used for development, tests and `npm run simulate`.

### Speaker detection

The streaming pipeline uses **Deepgram's diarization**: per-word speaker
indices from the provider are mapped to `speaker_1`, `speaker_2`, … in order
of first appearance and passed through verbatim — speakers are never inferred
from language or by alternating segments. The old language+gap heuristic
remains only as the batch-fallback assigner. A wrong speaker label never
blocks a translation.

### Language confidence

Every result carries `languageConfidence` and `transcriptionConfidence`.
Below 0.5 the app shows *"Language detected automatically"* instead of a
possibly-wrong language name. Very short utterances ("yes", "okay", "hello")
exist in many languages, so when they arrive with language confidence below
0.8 the server reports `sourceLanguage: "und"` rather than guessing.
Language detection never gates translation: every non-empty transcript goes
through the translation queue, even when the detected language equals the
target — detection can be wrong, and the translator (which detects the input
language itself from the text) simply returns already-target-language text
naturally unchanged.

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
