# Sayvo — Flutter app

See the root `README.md` for project setup and `docs/ARCHITECTURE.md` for the
full architecture. Short version: Firebase Auth/Firestore/App Check, and live
translation via a direct WebSocket to Gemini Live Translate using a
short-lived token minted by the `createLiveTranslateToken` Cloud Function.

## Structure

```
lib/
  main.dart                 Firebase init, App Check, provider wiring
  app.dart                  MaterialApp + AuthGate root
  features/
    auth/                   AuthGate, sign in/up, forgot password
    profile/                Account screen (target language, sign out, delete)
    live_translation/       Main screen, controller, chat bubbles
    history/                Firestore-backed session history
    settings/               Settings + privacy policy
    onboarding/             First-run language + microphone explainer
  services/
    gemini/                 LiveTranslationService (WebSocket), token client
    auth/                   AuthService (FirebaseAuth + Google + Apple), AuthController
    firestore/              UserRepository, SessionRepository
    audio/                  Mic capture bridge, PCM playback bridge
    permissions/            Mic permission wrapper
    storage/                Local settings mirror (SharedPreferences)
  utils/                    Language catalog, mic level math
```

## Running

```
flutter pub get
flutter run        # needs firebase_options.dart from `flutterfire configure`
flutter analyze
flutter test
```

Debug builds use App Check debug providers — on first run copy the debug
token from the console log into Firebase Console → App Check → your app →
Manage debug tokens.

## Native audio

Both platforms expose the same channels:
- `app.livetranslator/audio` (methods: start/stop, playbackStart/playbackChunk/playbackStop, micStatus/micRequest)
- `app.livetranslator/audio_events` (PCM16 capture chunks, stop events)
- `app.livetranslator/playback_events` ({"active": bool} while translated audio plays — drives the half-duplex mic gate)

iOS keeps the Podfile committed because of the `PERMISSION_MICROPHONE=1`
post-install hook (without it, mic permission reports denied forever).
Android runs capture inside a microphone foreground service with a visible
Stop notification.
