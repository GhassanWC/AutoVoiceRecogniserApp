# Live Translator — Mobile app (Flutter)

The app: onboarding (pick your language → understand mic access), the live
chat-style translation screen, opt-in local history, settings, Demo Mode.

## Run

```bash
flutter pub get
flutter run                 # Android device/emulator or iOS device
flutter test                # unit + widget tests
flutter analyze
```

> **Windows/OneDrive note:** if `flutter analyze`/IDE analysis crashes because
> this repo's path contains Arabic characters, map it to a drive letter first:
> `subst X: "<repo path>"` and work from `X:\mobile`.

### Demo Mode (no device, no backend, no API keys)

```bash
flutter run -d chrome
```

Then Settings → Developer → **Demo Mode** → Start Listening. A scripted
multilingual conversation streams into the UI exactly like real translations.

### Against the real backend

1. `cd ../backend && npm run dev`
2. Android emulator: just run the app — the default server URL
   `http://10.0.2.2:8080` reaches your host machine.
   Physical device / iOS simulator: set Settings → Developer → **Server URL**
   (e.g. `http://192.168.1.10:8080`; device and computer on the same network).
3. Press **Start Listening** and speak. With mock backend providers you get
   scripted text regardless of what you say; with real providers you get real
   transcription + translation.

## Platform specifics

### Android

- `android/app/src/main/kotlin/...`:
  - `AudioCaptureManager.kt` — `AudioRecord` @16 kHz mono PCM16, streams 100 ms
    chunks over an EventChannel; NoiseSuppressor/AEC/AGC attached when the
    device supports them; detects the mic being taken (returns `mic_lost`).
  - `ListeningForegroundService.kt` — microphone-type foreground service with
    the persistent "Live Translator is listening" notification + **Stop**
    action. `START_NOT_STICKY`: listening never auto-restarts.
  - `MainActivity.kt` — MethodChannel `app.livetranslator/audio`
    (`start`/`stop`/`isRunning`) and EventChannel
    `app.livetranslator/audio_events`.
- Manifest permissions: `RECORD_AUDIO`, `INTERNET`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`.
- Release builds: cleartext HTTP is blocked by default on Android 9+ — use an
  HTTPS server URL in production (the dev defaults work in debug builds).

### iOS

- All native code lives in `ios/Runner/AppDelegate.swift` (no pbxproj changes
  needed): `AVAudioEngine` capture, resampled to 16 kHz mono PCM16 via
  `AVAudioConverter`; interruptions (calls/Siri) end the session and inform
  the UI.
- `Info.plist`: `NSMicrophoneUsageDescription` + `UIBackgroundModes: [audio]`
  for background listening. No undocumented tricks; the system mic indicator
  stays visible.
- App Transport Security blocks plain HTTP — for on-device testing against a
  local dev server either use HTTPS or add a debug-only ATS exception.

## Where things are

```text
lib/features/live_translation/   main screen + controller (the state machine)
lib/services/audio/              platform-channel capture + VAD segmenter
lib/services/websocket/          reconnecting client (backoff, dedup, heartbeat)
lib/models/ws_events.dart        protocol — keep in sync with backend protocol.ts
lib/utils/languages.dart         language catalog (names, flags, RTL)
```

The VAD is pure Dart and fully unit-tested (`test/vad_segmenter_test.dart`) —
tune thresholds there if your environments differ (defaults: 800 ms silence
hangover, 10 s max segment, 350 ms pre-roll, adaptive noise floor).
