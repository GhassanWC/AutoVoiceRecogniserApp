#!/usr/bin/env python3
"""Convert SpeechBrain's VoxLingua107 ECAPA-TDNN spoken-language-ID model
(huggingface.co/speechbrain/lang-id-voxlingua107-ecapa, Apache-2.0) to a
Core ML model for fully on-device audio language identification.

Runs on the Codemagic macOS builder (Windows dev machines have no
Python/macOS toolchain). The output is a COMPILED .mlmodelc plus a
labels.json (index → ISO 639-1 code, with the model card's known label bugs
fixed: iw→he, jw→jv), dropped into ios/Runner/LanguageID/ for bundling.

Verification story (all inside this script — a broken conversion can never
ship):
1. torch.stft is replaced with an equivalent conv1d-based DFT BEFORE
   tracing, because coremltools' torch.stft conversion produced a graph
   that diverged from PyTorch at BOTH fp16 and fp32 (measured on CI:
   en 1.000 → ja 0.848 / lo 0.429). The replacement is verified numerically
   against the original IN EAGER PYTORCH first — a mistake in the manual
   DFT fails the build before conversion even starts.
2. The converted full model must match PyTorch on real audio (same top-1,
   max prob diff ≤ 0.05).
3. If it still diverges, the script converts the frontend (wav→features)
   and backend (features→probs) separately and prints per-stage parity, so
   the CI log names the broken stage instead of leaving us guessing.
4. Hard 100 MB size gate.

Fixed 5-second input window (80000 samples @ 16 kHz); the app tile-pads
shorter utterances.
"""

import json
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SAMPLE_RATE = 16000
WINDOW_SECONDS = 5
WINDOW_SAMPLES = SAMPLE_RATE * WINDOW_SECONDS
MAX_MODEL_MB = 100  # hard product limit
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

    fbank = classifier.mods.compute_features
    mean_var_norm = classifier.mods.mean_var_norm
    embedding_model = classifier.mods.embedding_model
    head = classifier.mods.classifier

    class WaveToLanguageProbs(torch.nn.Module):
        """Raw 16 kHz waveform [1, T] → language probabilities [1, N]."""

        def __init__(self):
            super().__init__()
            self.compute_features = fbank
            self.mean_var_norm = mean_var_norm
            self.embedding_model = embedding_model
            self.classifier = head

        def forward(self, wav):
            lengths = torch.ones(wav.shape[0])
            feats = self.compute_features(wav)
            feats = self.mean_var_norm(feats, lengths)
            embedding = self.embedding_model(feats, lengths)
            out = self.classifier(embedding)
            return torch.softmax(out.squeeze(1), dim=-1)

    class Frontend(torch.nn.Module):
        def forward(self, wav):
            lengths = torch.ones(wav.shape[0])
            return mean_var_norm(fbank(wav), lengths)

    class Backend(torch.nn.Module):
        def forward(self, feats):
            lengths = torch.ones(feats.shape[0])
            out = head(embedding_model(feats, lengths))
            return torch.softmax(out.squeeze(1), dim=-1)

    class ConvSTFT(torch.nn.Module):
        """Drop-in replacement for speechbrain.processing.features.STFT
        that computes the identical one-sided STFT with a single conv1d
        (framing + windowing + DFT fused into the kernel). Every op used
        (pad, conv1d, permute, stack) converts exactly to Core ML —
        unlike torch.stft, whose converted graph diverged on CI.
        Output layout matches SpeechBrain: [batch, time, n_freq, 2].
        """

        def __init__(self, original):
            super().__init__()
            n_fft = int(original.n_fft)
            self.n_fft = n_fft
            # SpeechBrain versions store hop_length either in ms (10) or in
            # samples (160); values ≤ 50 can only be ms at 16 kHz. The eager
            # parity check below catches any residual mismatch anyway.
            hop = float(original.hop_length)
            self.hop_length = int(round(hop)) if hop > 50 else int(
                round(original.sample_rate * hop / 1000.0))
            self.center = bool(original.center)
            self.pad_mode = str(original.pad_mode)
            if getattr(original, "normalized_stft", False):
                raise RuntimeError("normalized_stft not supported")
            window = original.window.detach().to(torch.float32)
            win_length = window.numel()  # the window IS win_length samples
            # torch.stft centers a shorter window inside n_fft.
            if win_length < n_fft:
                left = (n_fft - win_length) // 2
                padded = torch.zeros(n_fft)
                padded[left:left + win_length] = window
                window = padded
            n_freq = n_fft // 2 + 1
            n = torch.arange(n_fft, dtype=torch.float32)
            k = torch.arange(n_freq, dtype=torch.float32).unsqueeze(1)
            angle = 2.0 * math.pi * k * n / n_fft
            real_basis = torch.cos(angle) * window
            imag_basis = -torch.sin(angle) * window
            weight = torch.cat([real_basis, imag_basis], dim=0).unsqueeze(1)
            self.register_buffer("weight", weight)  # [2F, 1, n_fft]
            self.n_freq = n_freq

        def forward(self, x):
            # x: [batch, time]
            if self.center:
                mode = "constant" if self.pad_mode == "constant" else self.pad_mode
                x = torch.nn.functional.pad(
                    x.unsqueeze(1), (self.n_fft // 2, self.n_fft // 2),
                    mode=mode)
            else:
                x = x.unsqueeze(1)
            spec = torch.nn.functional.conv1d(
                x, self.weight, stride=self.hop_length)  # [B, 2F, T']
            real = spec[:, :self.n_freq, :]
            imag = spec[:, self.n_freq:, :]
            # → SpeechBrain layout [batch, time, n_freq, 2]
            return torch.stack(
                [real.permute(0, 2, 1), imag.permute(0, 2, 1)], dim=-1)

    with tempfile.TemporaryDirectory() as tmp:
        # ── Parity reference audio, prepared BEFORE any conversion ────────
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

        wrapper = WaveToLanguageProbs().eval()
        torch_probs = wrapper(signal).numpy()[0]
        torch_top = int(torch_probs.argmax())
        print(f"[LANGID] torch top-1: {labels[torch_top]} "
              f"({torch_probs[torch_top]:.3f})")
        torch_feats = Frontend().eval()(signal).numpy()

        # ── Replace torch.stft with the conv1d DFT, verified in eager ─────
        original_stft = fbank.compute_STFT
        conv_stft = ConvSTFT(original_stft).eval()
        stft_ref = original_stft(signal)
        stft_new = conv_stft(signal)
        if stft_ref.shape != stft_new.shape:
            sys.exit(f"[LANGID] FAIL: ConvSTFT shape {tuple(stft_new.shape)} "
                     f"!= SpeechBrain {tuple(stft_ref.shape)} — hop/window "
                     "interpretation bug, refusing to trace.")
        stft_diff = float((stft_ref - stft_new).abs().max())
        stft_scale = float(stft_ref.abs().max())
        print(f"[LANGID] ConvSTFT eager parity: max abs diff {stft_diff:.6f} "
              f"(signal scale {stft_scale:.1f})")
        if stft_diff > max(1e-3, 1e-5 * stft_scale):
            sys.exit("[LANGID] FAIL: ConvSTFT does not reproduce "
                     "SpeechBrain's STFT — script bug, refusing to trace.")
        fbank.compute_STFT = conv_stft
        patched_probs = wrapper(signal).numpy()[0]
        patched_diff = float(np.abs(torch_probs - patched_probs).max())
        print(f"[LANGID] patched-model eager parity: max prob diff "
              f"{patched_diff:.6f}")
        if patched_diff > 1e-3:
            sys.exit("[LANGID] FAIL: STFT replacement changed the model "
                     "output in eager mode — script bug.")

        example = torch.zeros(1, WINDOW_SAMPLES)
        print("[LANGID] tracing (with ConvSTFT) …")
        traced = torch.jit.trace(wrapper, example)

        def convert(module_traced, in_name, in_shape, out_name):
            return ct.convert(
                module_traced,
                inputs=[ct.TensorType(name=in_name, shape=in_shape,
                                      dtype=np.float32)],
                outputs=[ct.TensorType(name=out_name)],
                minimum_deployment_target=ct.target.iOS16,
                compute_precision=ct.precision.FLOAT32,
                convert_to="mlprogram",
            )

        print("[LANGID] converting full model to Core ML (fp32) …")
        mlmodel = convert(traced, "waveform", (1, WINDOW_SAMPLES),
                          "probabilities")
        pkg = Path(tmp) / f"{MODEL_NAME}.mlpackage"
        mlmodel.save(str(pkg))
        del mlmodel

        coreml_out = ct.models.MLModel(str(pkg)).predict(
            {"waveform": signal.numpy().astype(np.float32)})
        coreml_probs = np.array(coreml_out["probabilities"]).reshape(-1)
        coreml_top = int(coreml_probs.argmax())
        max_diff = float(np.abs(torch_probs - coreml_probs).max())
        print(f"[LANGID] coreml top-1: {labels[coreml_top]} "
              f"({coreml_probs[coreml_top]:.3f})  max prob diff {max_diff:.4f}")
        for rank, i in enumerate(np.argsort(-coreml_probs)[:5], start=1):
            print(f"[LANGID]   {rank}. {labels[int(i)]} {coreml_probs[int(i)]:.3f}")

        if coreml_top != torch_top or max_diff > 0.05:
            # ── Stage diagnostics: WHICH half is broken? ──────────────────
            print("[LANGID] full model diverges — running stage diagnostics …")
            front_traced = torch.jit.trace(Frontend().eval(), example)
            front_pkg = Path(tmp) / "front.mlpackage"
            convert(front_traced, "waveform", (1, WINDOW_SAMPLES),
                    "features").save(str(front_pkg))
            front_out = ct.models.MLModel(str(front_pkg)).predict(
                {"waveform": signal.numpy().astype(np.float32)})
            front_flat = np.array(front_out["features"]).reshape(-1)
            torch_flat = torch_feats.reshape(-1)
            if front_flat.size != torch_flat.size:
                print(f"[LANGID] FRONTEND output size {front_flat.size} != "
                      f"torch {torch_flat.size} — frontend broken (shape).")
            else:
                f_diff = float(np.abs(torch_flat - front_flat).max())
                f_scale = float(np.abs(torch_flat).max())
                print(f"[LANGID] FRONTEND (wav→feats) max abs diff "
                      f"{f_diff:.5f} (feature scale {f_scale:.1f})")

            back_traced = torch.jit.trace(
                Backend().eval(), torch.from_numpy(torch_feats))
            back_pkg = Path(tmp) / "back.mlpackage"
            convert(back_traced, "features", torch_feats.shape,
                    "probabilities").save(str(back_pkg))
            back_out = ct.models.MLModel(str(back_pkg)).predict(
                {"features": torch_feats.astype(np.float32)})
            back_probs = np.array(back_out["probabilities"]).reshape(-1)
            b_diff = float(np.abs(torch_probs - back_probs).max())
            b_top = int(back_probs.argmax())
            print(f"[LANGID] BACKEND (torch feats→probs) top-1 "
                  f"{labels[b_top]} ({back_probs[b_top]:.3f}), "
                  f"max prob diff {b_diff:.4f}")
            sys.exit("[LANGID] FAIL: Core ML full model diverges from "
                     "PyTorch — see stage diagnostics above for the broken "
                     "half. Refusing to ship it.")

        print("[LANGID] parity OK (fp32, ConvSTFT)")
        if labels[torch_top] != "en":
            print("[LANGID] WARNING: synthetic English clip not detected as "
                  "'en' (TTS audio is out-of-domain; informational only).")

        # ── Size gate ─────────────────────────────────────────────────────
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
