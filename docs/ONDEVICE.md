# On-device AI engine (experimental)

A/B experiment alongside the production OpenAI pipeline. Selected in
**Settings → Developer → Translation Engine**. With **On-device** selected:
no OpenAI calls, no backend speech API, no cloud translation, no API keys —
raw audio never leaves the iPhone.

```text
iPhone environmental microphone (UNCHANGED far-field capture + adaptive VAD)
    ↓ per utterance, PCM16 in RAM only
    ↓ MethodChannel app.livetranslator/whisperkit (Swift bridge in AppDelegate)
WhisperKit (Swift-native, Core ML, MIT — multilingual variants only,
            language auto-detected per utterance + script-analysis backup)
    ↓ transcript + ISO 639-1 code  →  "Speaker · Thai 🇹🇭" etc.
local translator (Phase A: passthrough; Phase B: M2M100)
    ↓
the SAME chat-bubble flow as the cloud engine (same messageId updates)
```

> **History**: Phase A originally used whisper.cpp via the
> `whisper_cpp_flutter_plus` FFI plugin. Its native model loader crashed the
> whole process on real iPhones (uncaught C++ exceptions across the FFI
> boundary → SIGABRT — see `IOS-LOCAL-STT-TRIAGE.md`), so the decision gate
> replaced it with WhisperKit. There is NO Dart FFI in the speech path
> anymore; a Swift failure surfaces as a catchable PlatformException. The
> old ggml downloads are auto-deleted once at app start
> (`legacy_model_cleanup.dart`).

## Model delivery: BUNDLED in the app, zero runtime downloads

WhisperKit's runtime downloader hung indefinitely on real iPhones, so it is
disabled outright (`download: false`; the bridge refuses to load anything not
in the bundle). Instead, CI bakes the model into the app
(`codemagic.yaml` → "Bundle WhisperKit Core ML model" + a verify gate):

- `Runner.app/WhisperModels/openai_whisper-small/` — the Core ML model
  (MelSpectrogram/AudioEncoder/TextDecoder `.mlmodelc`) from
  huggingface.co/argmaxinc/whisperkit-coreml, fetched at BUILD time;
- `Runner.app/WhisperModels/tokenizers/models/openai/whisper-small/` — the
  tokenizer JSONs from huggingface.co/openai/whisper-small, laid out exactly
  as WhisperKit's `tokenizerFolder` expects (the tokenizer is otherwise a
  SEPARATE runtime download that would hang the same way).

The Xcode project carries a folder reference to `ios/Runner/WhisperModels`
(git-ignored — it exists only during CI builds). Native model init has a
hard 30 s timeout; a failure reports the exact error instead of hanging.
This diagnostic build ships exactly ONE model — Whisper Small, multilingual —
and every settings key resolves to it (`whisperkit_models.dart`).

The WhisperKit SPM package (argmaxinc/WhisperKit, pinned 1.1.0) is a Runner
Xcode project dependency; it raised the iOS floor to 16.0. The IPA carries
the ~500 MB model — accepted for this diagnostic build.

## Phase A — validate local Whisper on a real iPhone (current state)

Wired end-to-end and unit-tested; **not yet validated on hardware** — that
is the point of the next TestFlight run:

0. Settings → Developer → **Test WhisperKit**: `Bundled model found: YES` →
   `Model load: PASS` (≤30 s) → speak → transcript + language must appear.
   Airplane mode changes NOTHING — the model is inside the app. This one
   test answers the build's question: can WhisperKit load and transcribe a
   model already stored on the iPhone? If it fails here, the on-device
   experiment stops and we move to the self-hosted API.
1. Settings → Developer → Translation Engine → On-device.
2. Enable Diagnostics Logging; airplane mode on, whenever you like.
3. Speak / play YouTube per language: English, Arabic, Thai, Bengali, Hindi —
   each bubble must show the correct transcript and language flag.
   Arabic → Arabic passes through complete (source == target).
   Other languages show the source transcript until Phase B.
4. Far-field: close speaker, 2 m, 4 m, TV at 3–4 m — the capture/VAD path is
   byte-identical to the cloud engine, so any regression is a bug.
5. Continuous runs: 5 / 15 / 30 minutes. Every utterance logs a `[LOCAL]`
   line with: audioMs, finalTranscriptMs, translateMs, speechEndToResultMs,
   thermal state (nominal/fair/serious/critical), battery %, app RAM MB
   (ProcessInfo/task_vm_info via the devicestats channel). Compare the first
   and last minutes for thermal throttling; note battery start/end.
6. If Turbo throttles (serious/critical, rising latency), retest with
   `small-q5_1`.

## Phase B — local translation (planned, interface already in place)

`LocalTranslator` (`local_translation_engine.dart`) is the slot. Plan:

- **Model**: facebook/m2m100_418M (MIT, ~100 languages, any→any) — one
  multilingual model, not dozens of pairs. Never ship the 1.94 GB FP32
  weights: INT8 quantization of the linear layers targets ~450–550 MB, added
  to the same download catalog with checksum + SentencePiece tokenizer
  (~2.4 MB).
- **Runtime**: export both a Core ML program (encoder + KV-cached decoder)
  and ONNX Runtime Mobile (ort, XNNPACK/CoreML EP); benchmark tokens/sec,
  RAM and thermal on the target iPhone; ship the winner.
- **Decoding**: greedy/beam-1 first (latency over polish), M2M100
  target-language forced-BOS convention; source language comes from Whisper.
- Source == target returns the text unchanged (already the Phase A behavior).

## Acceptance target (airplane mode after download)

Thai audio → Thai 🇹🇭 → Arabic; Bengali → Bengali 🇧🇩 → Arabic; English →
English 🇬🇧 → Arabic; السلام عليكم → Arabic 🇴🇲 → unchanged. Phase A proves
everything up to and including the language flag; Phase B completes the
Arabic output for cross-language pairs.
