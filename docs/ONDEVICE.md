# On-device engine — NATIVE platform speech + translation (production path)

Selected in **Settings → Developer → Translation Engine**:

- **Native on-device** (production goal): the phone's OWN speech recognition
  and translation. No WhisperKit, no whisper.cpp, no OpenAI, no self-hosted
  server, no paid cloud API. Audio never leaves the device.
- **Cloud (legacy/testing)**: the previous OpenAI pipeline, kept temporarily
  for comparison. Untouched.

```text
iOS
  environmental microphone + Dart VAD (UNCHANGED far-field capture)
      ↓ per-utterance PCM16 @ 16 kHz
  SFSpeechRecognizer, ON-DEVICE, one per product language IN PARALLEL
      → winner by recognizer confidence × NLLanguageRecognizer score
      (Apple's speech APIs are locale-fixed — SpeechTranscriber included —
       so source auto-detection is built from parallel per-locale
       recognition over the product set: en, ar, hi, th, bn [+ target])
      ↓ {text, detected language}
  Apple Translation framework (iOS 18+, on-device; packs download through
  Apple's own prepareTranslation flow — a 1×1 hidden SwiftUI host drives
  TranslationSession, since the framework is SwiftUI-bound below iOS 26)
      ↓
  existing chat bubbles (language name + flag, RTL Arabic, unchanged)

Android (pipeline arrives in an upcoming build; capability probe already real)
  on-device SpeechRecognizer (API 31+; audio language detection API 34+)
      ↓ {text, detected language}
  ML Kit on-device translation
      ↓ existing chat bubbles
```

The user still selects ONLY "Translate to: <language>". Source languages are
auto-detected per utterance — never configured.

## Capability check (never version-guessing, never a crash)

`LiveTranslationSupportService` (`services/native/live_translation_support.dart`,
channel `app.livetranslator/capabilities`) asks the OS APIs on THIS device:

- OS version; on-device speech per product language
  (`supportsOnDeviceRecognition` per locale on iOS;
  `isOnDeviceRecognitionAvailable` + SDK level on Android);
- automatic language detection (iOS: ≥2 on-device product languages for the
  parallel-recognition scheme; Android: API 34 language detection);
- on-device translation (iOS 18 `LanguageAvailability.status(from:to:)` per
  pair — "downloadable" is a pending pack, NOT an error).

Probed at app startup and again before Start Listening; "Check Again"
re-probes. Every failure path degrades to an honest `supported=false` result.

**Gating**: with the native engine selected on an unsupported device, Start
Listening is disabled ("Live Translation unavailable") and tapping it — or
the Settings row **On-device Live Translation → Status** — shows the modal:

- OS too old → "**Update required** — Live Translation requires a newer
  version of iOS/Android. Your current version is {version}." (never "your
  phone is unsupported" when an update could fix it);
- speech OK but detection/translation missing → "**Live Translation is not
  fully available**…";
- otherwise → "**⚠️ Live Translation unavailable** — Your device doesn't
  support the on-device features required for Live Translation. Update your
  phone's software and try again."  Buttons: Check Again / OK.

A platform that cannot auto-detect arbitrary sources is reported unsupported
for the full experience — the product is never silently reduced to a
two-language translator.

## Language packs

Apple downloads translation packs through its own UI (`prepareTranslation`),
triggered at session start ("Preparing Arabic translation…" while it runs).
A not-yet-downloaded pack is never surfaced as an error.

## History

whisper.cpp (`whisper_cpp_flutter_plus`) crashed natively on real iPhones
(SIGABRT through the FFI boundary); WhisperKit's runtime model downloader
hung indefinitely, and its CI-bundled-model build was superseded by this
native direction before validation. Both are fully removed — no Dart FFI, no
third-party ML runtime, no bundled models, no model CI steps. See
`IOS-LOCAL-STT-TRIAGE.md` for the forensic record. The one-shot legacy ggml
cleanup (`legacy_model_cleanup.dart`) still reclaims old downloads.

## Acceptance (real device, native engine)

Supported device: Start Listening → English/Thai/Bengali/Hindi → Arabic and
Arabic → Arabic, with no manual source selection. (Languages the device
lacks on-device recognition for are listed by the probe under
`missingLanguages` — expect Bengali/Thai to be missing on some devices; the
status dialog shows exactly what this hardware can hear.)
Unsupported device: Start disabled → clear modal → no crash, no endless
loading, no mysterious failure.
