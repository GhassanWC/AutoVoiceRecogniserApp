# Privacy model

Privacy is a product feature here, not a compliance checkbox. These are the
rules and where the code enforces them.

## The rules

1. **The microphone never starts on its own.**
   Only the explicit *Start Listening* action starts capture. Granting the OS
   permission does not start a session (`LiveTranslationController.startListening`
   is the only entry point; the Android service is `START_NOT_STICKY`, so the OS
   never resurrects it after reboot or kill).

2. **Listening is always visible.**
   In-app: the pulsing "● Listening" pill (text, not just color), tappable for
   an explanation and a Stop button. Android background: a persistent
   foreground-service notification with a Stop action. iOS: the system
   microphone indicator — never suppressed or worked around.

3. **Stop means stop, immediately.**
   *Stop Listening* tears down native capture first, then flushes/closes the
   session (`stopListening()` ordering). The notification Stop action kills
   capture natively before informing Dart.

4. **Silence never leaves the phone.**
   The VAD runs on-device; only detected-speech segments (plus a 350 ms
   pre-roll) are transmitted, over WSS/HTTPS in production.

5. **Raw audio is never stored.**
   The backend holds segment audio in memory only for the duration of the
   recognition call and discards it (`LiveSession.processSegment`). There is no
   audio column in the schema, no file writes, no object storage. The mobile
   app never writes audio to disk at all.

6. **History is opt-in, local, text-only.**
   `saveHistory` defaults to **off**. When on, translated conversations (text)
   are stored on the device via `HistoryStore`, deletable per-session or
   entirely (Settings → Delete history).

7. **Provider keys live on the server.**
   The app authenticates with a short guest JWT; OpenAI/Deepgram/Google keys
   exist only in backend environment variables.

8. **Logs carry metadata, not conversations.**
   The backend logger's contract (see `utils/logger.ts`): languages, latencies,
   lengths and ids — never transcribed or translated text at info level.

9. **No dark patterns around permissions.**
   A denied permission is respected: the app shows one clear banner
   ("Microphone access is disabled" + *Open Settings*) and never loops prompts.

10. **Local laws are the user's context.**
    The in-app privacy page tells users that recording/transcribing nearby
    speech is regulated differently across countries and to be transparent
    with people around them.

## Data inventory

| Data | Where | Retention |
|---|---|---|
| Audio segments | Backend RAM during one recognition call | Seconds; discarded immediately |
| Transcriptions/translations | Device (only if history is on); backend DB (only if a future server-history opt-in sends `saveHistory: true`) | User-deletable |
| Guest identity | JWT on device, user row in backend store | Until deleted |
| Usage metering | speech-seconds & character counts per month | Aggregates only |
| Diagnostics | Structured logs (no conversation content) | Operator-defined |

## What the app must never do

Hide microphone indicators, bypass OS privacy controls, record after Stop,
auto-restart listening after reboot, or circumvent Android/iOS microphone
policies. Any feature request that requires one of these is out of scope by
design.
