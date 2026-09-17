# Sayvo

Flutter iOS/Android app that listens to speech around you, auto-detects the
spoken language, and shows + speaks live translations into your chosen
language.

**Architecture:** Flutter → Firebase (Auth, Firestore, App Check) → Cloud
Function mints a short-lived Gemini ephemeral token → the app streams
microphone audio over a direct WebSocket to **Gemini Live Translate**
(`models/gemini-3.5-live-translate-preview`). See `docs/ARCHITECTURE.md`.

## Repo layout

```
mobile/      Flutter app
functions/   Firebase Cloud Functions (TypeScript) — Gemini token minting
docs/        Architecture + privacy rules
firebase.json, firestore.rules, .firebaserc   Firebase project config
codemagic.yaml   iOS TestFlight CI
```

## One-time setup

1. Create a Firebase project (Blaze plan), register the two apps:
   - iOS `com.ghassanalhattali.livetranslator`
   - Android `com.livetranslator.live_translator` (+ SHA-1/SHA-256 for Google Sign-In)
2. `dart pub global activate flutterfire_cli`, then in `mobile/`:
   `flutterfire configure` — generates `lib/firebase_options.dart` (committed),
   `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist`
   (both gitignored).
3. iOS: add the `REVERSED_CLIENT_ID` from `GoogleService-Info.plist` as a URL
   scheme in `mobile/ios/Runner/Info.plist` (CFBundleURLTypes) for Google
   Sign-In.
4. Android Google Sign-In: pass the OAuth *web* client ID at build time:
   `--dart-define=GOOGLE_SERVER_CLIENT_ID=xxx.apps.googleusercontent.com`.
5. Enable Auth providers (Email/Password, Google, Apple), create the Firestore
   database, register both apps in App Check (Play Integrity / App Attest)
   and add debug tokens for dev devices.
6. Put the project id in `.firebaserc`, then:
   ```
   firebase functions:secrets:set GEMINI_API_KEY
   cd functions && npm ci && npm test
   firebase deploy --only functions,firestore:rules,firestore:indexes
   ```

## Development

```
cd mobile
flutter pub get
flutter analyze && flutter test
flutter run
```

Functions: `cd functions && npm run typecheck && npm test`.

## CI (Codemagic)

`codemagic.yaml` builds + uploads the iOS TestFlight IPA. Required secure env
var in the `firebase-config` group: `GOOGLE_SERVICE_INFO_PLIST_B64` (base64 of
the iOS plist). Signing uses the `code-signing` group + the App Store Connect
integration; the build number auto-increments from TestFlight.
