# Privacy rules (enforced in code)

The app translates live speech via Google's Gemini Live Translate API.
Translation is **not** on-device — never claim that it is. These rules are
product law; each names the code that enforces it.

1. **The microphone never starts by itself.** Only the Start Listening button
   starts a session (`LiveTranslationController.startListening`); holding the
   OS permission never triggers capture. Android's foreground service is
   `START_NOT_STICKY`.

2. **Listening is always visible.** The pulsing "Listening" pill + waveform
   (`ListeningIndicator`) on screen, a persistent notification with a Stop
   action on Android, the OS microphone indicator on iOS.

3. **Stop means stop, immediately.** `LiveTranslationService.stop()` stops
   native capture FIRST, then closes the Gemini socket — not one extra sample
   is recorded or sent after Stop.

4. **Leaving the app stops the session.** `didChangeAppLifecycleState` stops
   listening when the app is backgrounded. No silent background capture.

5. **Audio streams only while listening, only to Gemini.** Microphone audio
   goes over one encrypted WebSocket directly to the Gemini Live API — never
   through Firebase, never to any other provider.

6. **Raw audio is never stored.** Not on the device, not in Firestore
   (`SessionRepository.addMessage` writes text fields only), not anywhere.

7. **History is text-only and private to the user.** Finalized original +
   translated text with detected language, stored under `users/{uid}` and
   protected by Firestore rules (`firestore.rules`) so no other user can ever
   read it. Delete history and delete account (which removes everything,
   `UserRepository.deleteAllUserData`) are one tap away.

8. **Secrets stay server-side.** The Gemini API key exists only in Secret
   Manager, read by the `createLiveTranslateToken` Cloud Function, which
   requires a signed-in user and a valid App Check token and returns only a
   short-lived, single-use, config-locked ephemeral token.

User-facing copy lives in `mobile/lib/features/settings/privacy_policy_screen.dart`
and must stay consistent with these rules.
