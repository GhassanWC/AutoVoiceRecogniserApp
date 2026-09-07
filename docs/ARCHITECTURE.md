# Architecture

> **Experimental on-device engine**: a fully offline Whisper-based pipeline
> can be selected in Settings → Developer → Translation Engine (A/B against
> the cloud pipeline below). See docs/ONDEVICE.md.

## The pipeline

```text
Environmental microphone (native: Android AudioRecord / iOS AVAudioEngine,
                          iOS: .measurement mode, voice-processing DSP off)
    ↓  16 kHz mono PCM16, ~100 ms chunks — streamed CONTINUOUSLY while
    ↓  listening (the local VAD only drives the waveform/diagnostics and a
    ↓  pause after ~30 s of absolute silence; it never gates room speech)
WebSocket  wss://…/live-translation                  ← binary frames + JSON control
    ↓
Backend LiveSession (one per connection)
    ↓  audio forwarded as it arrives (16 kHz PCM → resampled to 24 kHz)
PRIMARY: OpenAI gpt-realtime-translate (wss://…/v1/realtime/translations,
         one session per listening session; only the TARGET language is
         configured — source detection is automatic, no allowlist)
    ↓  translated transcript deltas, streamed while the speaker talks
transcript_final (bubble appears on the first translated word)
translation_delta … translation_delta (append into the SAME bubble)
translation_complete (full text + source transcript when available)
```

**Utterance-based failover** guards the primary path: the endpoint
occasionally returns sessions that accept audio but never emit a
translation. Utterance boundaries come from the provider's own
speech_started/speech_stopped events when the session emits them; otherwise
a server-side ADAPTIVE energy tracker detects them — threshold
max(0.0035, noiseFloor × 2) with hysteresis, floor following quiet audio —
never a fixed near-field level, so distant/TV speech is protected too. If
no direct delta arrived within ~1.4 s of speech end — a short "Hello"
included — that SAME utterance (held in a short in-memory buffer, never
persisted) is replayed under the SAME messageId through the FALLBACK
pipeline, and the rest of the session stays there: GA realtime transcription
(gpt-4o-transcribe, `?intent=transcription`, far_field, server VAD 300 ms)
→ transcript_final → streaming text translation queue (concurrency 2,
retries on 408/429/5xx/network) → the same delta/complete events. Late
output from the abandoned session is ignored, so no duplicate bubbles.
Diarization is out of the critical path (speaker labels show the generic
"Speaker"); every OpenAI server event type is logged (`[OPENAI] <type>` /
`[OPENAI ERROR] …`) so a silently-rejected session config can never again
look like "listening but silent".

Latency is measured per utterance from the provider's speech-end signal:
`speechEndToFirstDeltaMs` and `speechEndToFinalMs` ride on
`translation_complete`, are logged in the app's developer diagnostics, and
the backend logs p50/p95 every 10 utterances. Target: first translated words
well under a second after a short phrase ends.

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

The realtime stream lives for the whole session, so switching languages
mid-conversation needs no reconnect or reconfiguration, and diarized speaker
ids stay stable across the conversation. Server turn detection is disabled —
the phone's VAD owns segmentation, and each client segment end commits the
audio buffer, which finalizes one transcription. There is **no source-language
allowlist** on this path: Arabic, Thai, Chinese or anything else the model can
hear is transcribed; the speech stage reports `sourceLanguage: "und"` and the
translation stage — which reads the actual text — is the authoritative
language detector.

`mock` falls back to the per-segment batch pipeline (PCM → WAV → transcribe →
heuristic speakers), the live pipeline falls back to it (whisper-1) if the
stream errors mid-session, and the optional `deepgram` provider (nova-3
`language=multi`, ten-language code-switching limit in
`NOVA3_MULTI_LANGUAGES`) remains behind the same abstraction but is not part
of the MVP.

**Real provider smoke test:** `npm run verify:providers` calls the actually
configured speech + translation APIs (TTS-generated Arabic/English fixtures →
transcription; "Good morning." / "Hello." / "السلام عليكم" → Arabic
translation) and prints PASS or the concrete HTTP status and provider error.
Run it whenever the app shows failing translations — mocked unit tests do not
prove provider health.

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
| `StreamingSpeechProvider` | **`openai` (production: realtime WS, gpt-4o-transcribe-diarize, far_field)**, `deepgram` (optional: nova-3, `language=multi`, `diarize_model=latest`) | `SPEECH_PROVIDER` |
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
