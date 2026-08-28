# Live Translator

A real-time **automatic surrounding-language translator**. Press one button, put the
phone down, and read everything spoken around you — in your own language.

- **No source-language selection, ever.** Each utterance is language-detected
  automatically; Spanish, English, French, Thai… can all occur in the same session.
- **Chat-style conversation UI** with speaker labels (`Speaker 1 · Spanish 🇪🇸`),
  the translation as the hero text and the original underneath.
- **First-class Arabic/RTL** rendering with proper bidirectional text handling.
- **Privacy-first**: microphone only runs while the visible "Listening" session is
  active, silence never leaves the phone, raw audio is never stored, history is
  opt-in and local.

```text
Speaker 1 · Spanish 🇪🇸        Speaker 2 · English 🇬🇧       Speaker 3 · French 🇫🇷
مرحباً يا أخي                   أمي مريضة                     أين الفندق؟
Hola hermano.                  My mother is sick.            Où est l'hôtel?
```

## Repository layout

```text
backend/   Node.js + TypeScript API & WebSocket server (speech → translation pipeline)
mobile/    Flutter app (Android & iOS; UI also previews on web/desktop in Demo Mode)
docs/      Architecture & privacy documentation
```

## Quick start — backend (works immediately, no API keys)

Requires Node.js ≥ 18.

```bash
cd backend
npm install
npm run dev          # starts on http://localhost:8080 with mock AI providers
```

In a second terminal, watch the full pipeline translate a fake conversation:

```bash
cd backend
npm run simulate
# [Speaker 1 · es] Hola hermano, ¿cómo estás?  →  مرحباً يا أخي، كيف حالك؟
# [Speaker 2 · en] My mother is sick.          →  أمي مريضة.
# [Speaker 3 · fr] Où est l'hôtel?             →  أين الفندق؟
```

To use real AI providers, copy `backend/.env.example` to `backend/.env` and set
`SPEECH_PROVIDER=openai` (or `deepgram`) and `TRANSLATION_PROVIDER=openai` (or
`google`) with the matching API keys. Keys live **only** on the backend.

## Quick start — mobile

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(this machine: `C:\Users\gassa\dev\flutter`) and, for Android builds,
Android Studio / the Android SDK.

```bash
cd mobile
flutter pub get
flutter run                    # on an Android device/emulator or iOS device
```

- **Instant UI preview without any device or backend:** run
  `flutter run -d chrome`, then enable **Settings → Developer → Demo Mode** and
  press *Start Listening* — a fake multilingual conversation streams in.
- **Real pipeline:** start the backend, run the app on Android
  (emulator reaches the host via the default `http://10.0.2.2:8080`), press
  *Start Listening* and speak. For a physical device set
  **Settings → Developer → Server URL** to your machine's LAN address, e.g.
  `http://192.168.1.10:8080`.

### Windows note: Arabic characters in this project's path

The Dart analysis server currently crashes on paths containing non-ASCII
characters (this repo lives under `OneDrive\المستندات`). Workaround — map the
project to a drive letter and run Flutter commands from there:

```powershell
subst X: "C:\Users\gassa\OneDrive\المستندات\projects\AutoVoiceRecogniserApp"
cd X:\mobile
flutter analyze
```

(`subst X: /D` removes the mapping; it also disappears on reboot.)

## Testing

```bash
cd backend && npm test        # 23 tests: pipeline, protocol, diarization, auth…
cd mobile  && flutter test    # 20 tests: VAD, RTL rendering, protocol, models…
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — pipeline, WebSocket protocol,
  provider abstraction, background-audio design, MVP phasing.
- [docs/PRIVACY.md](docs/PRIVACY.md) — the privacy model and the rules the code
  enforces.
- [backend/README.md](backend/README.md) — API reference, environment variables,
  PostgreSQL setup, deployment.
- [mobile/README.md](mobile/README.md) — app structure, platform specifics,
  Android foreground service, iOS background audio.
