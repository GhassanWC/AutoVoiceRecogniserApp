# iOS local STT triage — the two real-iPhone failures

Status: 2026-09-08. Phase B is frozen until the acceptance gate below passes
on TestFlight. The cloud/OpenAI engine is untouched.

---

## Failure 1 — "microphone access denied" while iOS Settings shows GRANTED

**Root cause (confirmed in source, not inferred):** `permission_handler_apple`
ships with every permission compiled OUT by default. Its
`PermissionHandlerEnums.h` contains:

```objc
#ifndef PERMISSION_MICROPHONE
    #define PERMISSION_MICROPHONE 0
#endif
```

and with the macro at 0, `AudioVideoPermissionStrategy.m` hard-returns
`PermissionStatusDenied` from `checkPermissionStatus` and from
`requestPermission` — unconditionally, without ever consulting iOS. Enabling
a permission requires `PERMISSION_MICROPHONE=1` in the app Podfile's
`post_install`. Our committed `mobile/ios/Podfile` (created for the whisper
dynamic-linking fix) did not define it, so **the plugin reported "denied"
forever while the OS permission was granted**. Start Listening trusted the
plugin and refused.

**Fixes applied (both):**

1. iOS microphone permission is now read and requested **natively**
   (`AVAudioSession.recordPermission` / `requestRecordPermission` in
   `AppDelegate.swift`, exposed as `micStatus` / `micRequest` /
   `micDiagnostics` on the existing `app.livetranslator/audio` channel).
   `MicPermissionService` consults the native state first on iOS; a native
   "granted" is final and no plugin answer can veto it. The request fires
   only when the native state is genuinely `undetermined`, and only through
   this one path — never through two competing libraries.
2. The Podfile now defines `PERMISSION_MICROPHONE=1` for
   `permission_handler_apple`, so the plugin tells the truth wherever it is
   still consulted (and on any future non-iOS surface).

**New diagnostic:** Settings → Developer → **Test Microphone Permission**.
It prints the `[MIC PERMISSION]` block (flutter vs native status, usage
description presence, session category/mode/active), requests permission only
if undetermined, then captures 2 seconds of PCM through the exact native
pipeline Start Listening uses and reports `Audio capture: PASS` with
byte/sample/peak/RMS evidence. Whisper is never loaded.

---

## Failure 2 — Test Offline Model kills the whole app

The Test button never touches the microphone (verified: `runModelLoadTest`
does filesystem prechecks + `WhisperEngine.load` only). The process dying
means a **native** SIGABRT/SIGSEGV or a jetsam out-of-memory kill — a Dart
try/catch cannot see any of these.

**Crash-evidence sentinel (new):** a `whisper_load_attempt.json` file is
written immediately before every native whisper FFI call (both the Test
button and Start Listening) and deleted the moment the call returns. If the
process dies inside the call, the sentinel survives, and the next run of Test
Offline Model opens with a `[WHISPER NATIVE CRASH EVIDENCE]` block naming the
exact phase (`native_library_probe` vs `native_model_load`), the model, and
the timestamp.

**Getting the real native stack (required for the decision gate):**

- On the iPhone: Settings → Privacy & Security → Analytics & Improvements →
  Analytics Data → newest `Runner-…` / `live_translator-…` `.ips` file →
  share it.
- Or: App Store Connect → TestFlight → Crashes (also visible in Xcode
  Organizer). TestFlight builds symbolicate automatically once dSYMs are
  uploaded (Codemagic uploads them with the archive).
- In the report: `Exception Type` (SIGABRT vs SIGSEGV vs
  `EXC_RESOURCE / memory`) and the top frames of the crashed thread name the
  crashing function/library. That is the ground truth; a Dart-side message is
  not.

**Static analysis of the plugin (whisper_cpp_flutter_plus 0.4.1) — the
likeliest crashing paths, in order:**

1. **Uncaught C++ exception across the FFI boundary → SIGABRT.**
   `wf_context_create` (`WhisperCppFlutterBridge/whisper_flutter.cpp`) has
   **no try/catch**, while whisper.cpp deliberately throws:
   `whisper_backend_init` does
   `throw std::runtime_error("failed to initialize CPU backend")`, and
   ggml/whisper buffer allocation can throw `std::bad_alloc` or trip
   `GGML_ASSERT` → `abort()`. Any of these escaping an `extern "C"` function
   is `std::terminate` → SIGABRT. Crash-report signature: crashed thread in
   `abort` / `std::terminate` / `__cxa_throw` with `whisper_init_*` or
   `ggml_*` frames below.
2. **Out-of-memory kill.** The default catalog model is
   `large-v3-turbo-q5_0` (574 MB on disk; >1 GB resident once loaded with
   compute buffers) — and it loads on **CPU**, because the pod's Metal
   library init fails (see 3), so no GPU-shared memory relief. Signature:
   `EXC_RESOURCE` / "was killed for using too much memory" — or no `.ips`
   crash at all, just a vanished app. Mitigation to test first:
   **select the `small-q5_1` baseline model before pressing Test**.
3. **Broken Metal resource in the CocoaPods build.** The podspec bundles the
   Metal shader source as `ggml-metal.txt`, but `ggml-metal-device.m` looks
   for `default.metallib` / `ggml-metal.metal` — never a `.txt`. Metal
   library init therefore returns nil on every device. whisper logs
   "failed to initialize Metal backend" and falls back to CPU (feeding
   candidate 2); on some paths a nil library is followed by
   `GGML_ABORT("fatal error")` pipeline lookups.

---

## Decision gate (unchanged from the plan)

Continue with `whisper_cpp_flutter_plus` on iOS **only if both pass on the
next TestFlight build**:

- Test Microphone Permission: PASS
- Test Offline Model: PASS (try `small-q5_1` first, then the Turbo model)

If Test Offline Model still dies natively, stop investing in the plugin and
switch the Phase A iOS local engine to **WhisperKit** (below). The
`[WHISPER NATIVE CRASH EVIDENCE]` block plus the `.ips` report from the failed
run decide it — not a Dart exception.

---

## WhisperKit replacement plan (ready to execute)

**Why WhisperKit fits:** Swift-native (no C++ exceptions crossing FFI, no
dlsym, no Metal-resource packaging traps), Core ML + ANE (lower memory and
battery than CPU ggml), MIT licensed, streaming microphone transcription and
per-utterance language detection, actively maintained by Argmax.

**Shape (the app/UI stays; one small bridge):**

```
Flutter (unchanged UI + VAD + pipeline)
   ↓ MethodChannel  app.livetranslator/whisperkit   (load/transcribe/unload)
   ↓ EventChannel   app.livetranslator/whisperkit_events  (partial results)
Swift bridge (one file, registered in AppDelegate like AudioCaptureManager)
   ↓
WhisperKit (SPM package, Core ML)
   ↓
{ text, detected language } → Flutter
```

**Integration steps when the gate fails:**

1. Add the SPM package to the Runner project (Xcode → Runner → Package
   Dependencies → `https://github.com/argmaxinc/WhisperKit`, exact version
   pin). CocoaPods for Flutter plugins and an SPM package for the app target
   coexist fine; commit the `project.pbxproj` + `Package.resolved` diff.
2. Add `WhisperKitBridge.swift` to the Runner target: a
   `FlutterMethodChannel` handler owning one `WhisperKit` instance —
   `load(model:)` (downloads/uses the bundled Core ML model variant, e.g.
   `openai_whisper-small` or `large-v3_turbo`), `transcribe(pcmFloat32:)`
   returning `{text, language}`, `unload`. Register it in
   `didInitializeImplicitFlutterEngine` next to the audio channel.
3. Dart side: implement `WhisperKitSpeechEngine implements LocalSpeechEngine`
   (same `load / transcribe / dispose` surface — `local_speech_engine.dart`
   is already the only file touching the current plugin, so the swap is one
   factory change in the controller + settings test button).
4. Model management: WhisperKit fetches Core ML models from the Hugging Face
   `argmaxinc/whisperkit-coreml` repo; wire its download progress into
   `OfflineModelManager`'s existing states (or keep WhisperKit's own cache and
   surface only ready/size/delete).
5. Keep multilingual-only variants (never `.en`) and per-utterance
   `language: auto`, matching the product rule.
6. Remove `whisper_cpp_flutter_plus`, the Podfile dynamic-linking workaround,
   the `-u wf_*` linker pins in `Flutter/*.xcconfig`, and the CI symbol gate
   in `codemagic.yaml` — all of it exists only to serve the old plugin.

**Cost estimate:** bridge ≈ 150 lines of Swift + ≈ 80 lines of Dart; UI,
VAD, pipeline, history, settings all unchanged.

---

## Acceptance before Phase B (on a real iPhone via TestFlight)

1. Microphone permission = GRANTED (native)
2. 2-second local audio capture = PASS
3. Local model load = PASS
4. English transcription = PASS
5. Arabic transcription = PASS

Only after all five: local translation (Phase B).
