#!/usr/bin/env python3
"""Convert SpeechBrain's VoxLingua107 ECAPA-TDNN spoken-language-ID model
(huggingface.co/speechbrain/lang-id-voxlingua107-ecapa, Apache-2.0) to a
Core ML model for fully on-device audio language identification.

Runs on the Codemagic macOS builder (Windows dev machines have no
Python/macOS toolchain). The output is a COMPILED .mlmodelc plus a
labels.json (index → ISO 639-1 code, with the model card's known label bugs
fixed: iw→he, jw→jv), dropped into ios/Runner/LanguageID/ for bundling.

The build gate (verify step in codemagic.yaml) relies on this script's own
verification: the converted Core ML model must NUMERICALLY match the
original PyTorch model on real audio (same top-1, small max prob diff) —
conversion bugs fail the build, never the iPhone.

End-to-end graph traced from the RAW WAVEFORM (fbank + normalization +
ECAPA + classifier + softmax), so the app needs no hand-written DSP that
could drift from training-time features. Fixed 5-second input window
(80000 samples @16 kHz); the app tile-pads shorter utterances.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SAMPLE_RATE = 16000
WINDOW_SECONDS = 5
WINDOW_SAMPLES = SAMPLE_RATE * WINDOW_SECONDS
MAX_MODEL_MB = 100  # hard product limit; ~45 MB expected at fp16
OUT_DIR = Path("ios/Runner/LanguageID")
MODEL_NAME = "VoxLingua107LangID"

# Model-card known label fixes (obsolete/incorrect ISO codes).
LABEL_FIXES = {"iw": "he", "jw": "jv"}


def main() -> None:
    import wave

    import coremltools as ct
    import numpy as np
    import torch
    from speechbrain.inference.classifiers import EncoderClassifier

    torch.set_grad_enabled(False)

    print("[LANGID] loading speechbrain/lang-id-voxlingua107-ecapa …")
    classifier = EncoderClassifier.from_hparams(
        source="speechbrain/lang-id-voxlingua107-ecapa",
        savedir="langid_hf_cache",
        run_opts={"device": "cpu"},
    )
    classifier.eval()

    ind2lab = classifier.hparams.label_encoder.ind2lab
    labels = []
    for i in range(len(ind2lab)):
        raw = str(ind2lab[i]).strip()
        # Labels look like "th: Thai" in some releases; keep the code part.
        code = raw.split(":")[0].strip()
        labels.append(LABEL_FIXES.get(code, code))
    print(f"[LANGID] {len(labels)} languages, e.g. {labels[:8]} …")

    class WaveToLanguageProbs(torch.nn.Module):
        """Raw 16 kHz waveform [1, T] → language probabilities [1, N]."""

        def __init__(self, cls):
            super().__init__()
            self.compute_features = cls.mods.compute_features
            self.mean_var_norm = cls.mods.mean_var_norm
            self.embedding_model = cls.mods.embedding_model
            self.classifier = cls.mods.classifier

        def forward(self, wav):
            lengths = torch.ones(wav.shape[0])
            feats = self.compute_features(wav)
            feats = self.mean_var_norm(feats, lengths)
            embedding = self.embedding_model(feats, lengths)
            out = self.classifier(embedding)
            return torch.softmax(out.squeeze(1), dim=-1)

    wrapper = WaveToLanguageProbs(classifier).eval()
    example = torch.zeros(1, WINDOW_SAMPLES)
    print("[LANGID] tracing …")
    traced = torch.jit.trace(wrapper, example)

    print("[LANGID] converting to Core ML (fp16, ALL compute units) …")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="waveform", shape=(1, WINDOW_SAMPLES),
                              dtype=np.float32)],
        outputs=[ct.TensorType(name="probabilities")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    with tempfile.TemporaryDirectory() as tmp:
        pkg = Path(tmp) / f"{MODEL_NAME}.mlpackage"
        mlmodel.save(str(pkg))

        # ── Verification 1: numeric parity on real audio ──────────────────
        # Real speech via macOS TTS (`say`) — the gate is CONVERSION
        # FIDELITY (torch vs coreml agreement), not model quality; quality
        # is judged on the real iPhone per the product gate.
        wav_path = Path(tmp) / "sample.wav"
        aiff = Path(tmp) / "sample.aiff"
        subprocess.run(
            ["say", "-o", str(aiff),
             "The weather is lovely today and tomorrow looks even better."],
            check=True)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
             str(aiff), str(wav_path)], check=True)
        # Stdlib WAV read (afconvert wrote plain PCM16 LE mono) — no
        # torchaudio backend needed, so the "no working audio backend"
        # warning on the CI Mac is harmless.
        with wave.open(str(wav_path), "rb") as reader:
            assert reader.getframerate() == SAMPLE_RATE, \
                f"unexpected sample rate {reader.getframerate()}"
            assert reader.getnchannels() == 1, "expected mono"
            pcm = reader.readframes(reader.getnframes())
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        signal = torch.from_numpy(samples).unsqueeze(0)
        if signal.shape[1] < WINDOW_SAMPLES:  # tile-pad exactly like the app
            reps = WINDOW_SAMPLES // signal.shape[1] + 1
            signal = signal.repeat(1, reps)
        signal = signal[:, :WINDOW_SAMPLES]

        torch_probs = wrapper(signal).numpy()[0]
        coreml_out = ct.models.MLModel(str(pkg)).predict(
            {"waveform": signal.numpy().astype(np.float32)})
        coreml_probs = np.array(coreml_out["probabilities"]).reshape(-1)

        torch_top = int(torch_probs.argmax())
        coreml_top = int(coreml_probs.argmax())
        max_diff = float(np.abs(torch_probs - coreml_probs).max())
        print(f"[LANGID] torch top-1: {labels[torch_top]} "
              f"({torch_probs[torch_top]:.3f})")
        print(f"[LANGID] coreml top-1: {labels[coreml_top]} "
              f"({coreml_probs[coreml_top]:.3f})  max prob diff {max_diff:.4f}")
        for rank, i in enumerate(np.argsort(-coreml_probs)[:5], start=1):
            print(f"[LANGID]   {rank}. {labels[int(i)]} {coreml_probs[int(i)]:.3f}")
        if torch_top != coreml_top or max_diff > 0.05:
            sys.exit("[LANGID] FAIL: Core ML output diverges from PyTorch — "
                     "conversion is broken, refusing to ship it.")
        if labels[coreml_top] != "en":
            print("[LANGID] WARNING: synthetic English clip not detected as "
                  "'en' (TTS audio is out-of-domain; informational only).")

        # ── Verification 2: size gate ─────────────────────────────────────
        pkg_mb = sum(f.stat().st_size for f in pkg.rglob("*") if f.is_file()) \
            / (1024 * 1024)
        print(f"[LANGID] mlpackage size: {pkg_mb:.1f} MB (limit {MAX_MODEL_MB})")
        if pkg_mb > MAX_MODEL_MB:
            sys.exit(f"[LANGID] FAIL: model {pkg_mb:.1f} MB exceeds the "
                     f"{MAX_MODEL_MB} MB product limit.")

        # ── Compile for the bundle (app loads .mlmodelc directly) ─────────
        if OUT_DIR.exists():
            shutil.rmtree(OUT_DIR)
        OUT_DIR.mkdir(parents=True)
        subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(pkg), str(OUT_DIR)],
            check=True)
        (OUT_DIR / "labels.json").write_text(json.dumps(labels))
        (OUT_DIR / "model_info.json").write_text(json.dumps({
            "source": "speechbrain/lang-id-voxlingua107-ecapa",
            "license": "Apache-2.0",
            "windowSamples": WINDOW_SAMPLES,
            "sampleRate": SAMPLE_RATE,
            "mlpackageMB": round(pkg_mb, 1),
        }))
        bundled_mb = sum(f.stat().st_size for f in OUT_DIR.rglob("*")
                         if f.is_file()) / (1024 * 1024)
        print(f"[LANGID] bundled (compiled) size: {bundled_mb:.1f} MB → {OUT_DIR}")
        print("[LANGID] PASSED")


if __name__ == "__main__":
    main()
