# On-device engine — NATIVE platform speech + translation (production path)

> **ARCHITECTURE CHANGE IN PROGRESS (2026-09-11): audio language ID first.**
> Final product: the user picks ONLY the target language; a small on-device
> Core ML detector (VoxLingua107 ECAPA, SpeechBrain, Apache-2.0, 107
> languages, ~45 MB fp16, converted+verified at CI time by
> `tools/convert_langid_coreml.py` — numeric-parity gate vs PyTorch, 100 MB
> hard size limit) identifies the SPOKEN language from each VAD utterance's
> AUDIO, then exactly ONE Apple recognizer runs for that language
> (`AppleSpeechLocaleResolver` priority: installed SpeechTranscriber →
> on-device SFSpeechRecognizer → network SFSpeechRecognizer → honest
> "recognition unavailable for {language}"; downloads never block Start).
> GATE: Settings → Developer → **Test Language Detection** (detector only,
> no speech recognition) must pass on a real iPhone in EN/AR/HI/TH/BN
> before the session pipeline, Listen-for UI removal, and single-recognizer
> flow land. The confidence threshold is tuned from those device runs, not
> hardcoded. Until then the selected-languages pipeline below remains
> active.

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

**Language model (the product promise):** "Choose the languages around you
once, then Live Translator automatically understands which one is being
spoken." The user picks ONE target ("Translate to: Arabic") and ONE OR MORE
"Listen for" languages (`AppSettings.listenLanguages`, first-run default:
English only — never a silently-downloaded world list). Every utterance is
auto-detected among exactly the selected languages; one selected language is
fully valid and runs a single recognizer (fastest path). Five concepts stay
strictly separate: supportedLocales (device capability), installedLocales
(downloaded), reservedLocales (app's asset slots, capped by the LIVE
`AssetInventory.maximumReservedLocales` — never hardcoded), the user's
selection, and the target. UI: the main screen shows Translate to + Listen
for chips (+ Add language → picker fed by supportedLocales, unsupported
entries disabled); Settings → Listening Languages manages Download/Remove
(slot release via `AssetInventory.release(reservedLocale:)`, always
user-chosen). Start Listening downloads any selected pending packs with
per-language progress and then starts automatically. A device is
"unsupported" ONLY when the native architecture is missing — never because
packs aren't downloaded and never because fewer than two languages are
installed.

## Capability check (never version-guessing, never a crash)

`LiveTranslationSupportService` (`services/native/live_translation_support.dart`,
channel `app.livetranslator/capabilities`) asks the OS APIs on THIS device,
keeping **SUPPORTED and INSTALLED strictly apart** — a supported-but-not-
downloaded model is `downloadRequired`, never "unsupported":

- iOS 26+: `SpeechTranscriber.supportedLocales` is the CAPABILITY list;
  `SpeechTranscriber.installedLocales` only says what is downloaded.
  `SFSpeechRecognizer.supportsOnDeviceRecognition` is NOT used as the
  capability test there (it reflects installed dictation assets only — the
  bug that made an iPhone 16 Pro Max report just "en"). Diagnostics print
  `supportedLocales= / installedLocales= / reservedLocales= /
  maximumReservedLocales=`. Pre-26 falls back to `SFSpeechRecognizer`
  (no supported/installed split exists there).
- Missing supported models install through Apple's own
  `AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()`
  — Settings → status dialog → **Prepare Live Translation** (per-language
  progress), and automatically at session start; the capability check
  re-runs after installation. Recognition on iOS 26 uses
  SpeechAnalyzer/SpeechTranscriber (the stack those assets power).
- automatic language detection (≥2 SUPPORTED product languages for the
  parallel-recognition scheme; Android: API 34 language detection);
- on-device translation (iOS 18 `LanguageAvailability.status(from:to:)` per
  pair — "downloadable" is a pending pack, NOT an error).

The status dialog lists each product language as `Ready ✓`,
`Download required`, or `Unsupported` (only when absent from
`supportedLocales`).

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
