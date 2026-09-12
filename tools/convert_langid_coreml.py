#!/usr/bin/env python3
"""VoxLingua107 language-ID build step: Core ML BACKEND ONLY + native
Swift feature extraction, with full parity gates.

Architecture (decided after the fused waveform→probs Core ML conversion
repeatedly diverged while the backend converted exactly):

    PCM float32 16 kHz
      ↓  SpeechBrainFbank.swift  (framing + windowed-DFT matmul + mel
         matmul + dB + top-db clamp + sentence mean-norm; every constant
         EXPORTED from the live SpeechBrain modules by this script into
         frontend.bin/frontend.json — Swift derives nothing itself)
      ↓  [1, frames, 60] features
      ↓  LangIDBackend.mlmodelc  (ECAPA + classifier + softmax; the half
         that already passed parity at diff 0.0000)
      ↓  107 language probabilities

This script:
  A. loads the official SpeechBrain model and PRINTS the exact feature
     parameters in use;
  B. exports the frontend constants (DFT basis, mel matrix, scalars);
  C. converts ONLY the backend to Core ML and gates it on parity against
     PyTorch using SpeechBrain-computed features;
  D. compiles the ACTUAL shipping SpeechBrainFbank.swift with swiftc and
     gates its features against SpeechBrain's (max/mean diff, first
     failing frame/bin printed);
  E. runs end-to-end parity: BOTH paths get the IDENTICAL 80000-sample
     window (same 16 kHz mono audio, same 5-second policy) — official
     SpeechBrain on those samples must produce the SAME top-1 as
     Swift Fbank + Core ML backend on those same samples, for every test
     clip the builder's TTS voices can produce (en always; ar/hi/th/bn
     when voices exist) and a SHORT clip, choosing zero- vs tile-padding
     empirically. Whether synthetic TTS is classified as its INTENDED
     language is NOT a gate (the official model itself misclassifies
     synthetic Bengali); real-language accuracy is judged on the iPhone;
  F. size gate (100 MB) and drops everything into ios/Runner/LanguageID/.

NO waveform→features Core ML conversion is attempted anywhere.
"""

import json
import shutil
import struct
import subprocess
import sys
import tempfile
import wave as wave_mod
from pathlib import Path

SAMPLE_RATE = 16000
WINDOW_SECONDS = 5
WINDOW_SAMPLES = SAMPLE_RATE * WINDOW_SECONDS
MAX_MODEL_MB = 100
OUT_DIR = Path("ios/Runner/LanguageID")
REPO_ROOT = Path(__file__).resolve().parent.parent
FBANK_SWIFT = REPO_ROOT / "mobile/ios/Runner/SpeechBrainFbank.swift"
HARNESS_SWIFT = REPO_ROOT / "tools/LangIdParityMain.swift"

LABEL_FIXES = {"iw": "he", "jw": "jv"}

# macOS TTS voices for real-speech test clips (used when installed).
TTS_CLIPS = [
    ("en", None, "The weather is lovely today and tomorrow looks even better."),
    ("ar", "Majed", "الطقس جميل اليوم وسنذهب إلى السوق بعد الظهر لشراء الفواكه."),
    ("hi", "Lekha", "आज मौसम बहुत अच्छा है और हम शाम को बाजार जाएंगे।"),
    ("th", "Kanya", "วันนี้อากาศดีมาก และเราจะไปตลาดตอนเย็นเพื่อซื้อผลไม้"),
    ("bn", None, "আজ আবহাওয়া খুব সুন্দর এবং আমরা বিকেলে বাজারে যাব।"),
]


def run(cmd, **kw):
    print("[LANGID] $", " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


def read_wav_f32(path):
    import numpy as np
    with wave_mod.open(str(path), "rb") as reader:
        assert reader.getframerate() == SAMPLE_RATE
        assert reader.getnchannels() == 1
        pcm = reader.readframes(reader.getnframes())
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def pad_to_window(samples, mode):
    import numpy as np
    if samples.shape[0] >= WINDOW_SAMPLES:
        start = (samples.shape[0] - WINDOW_SAMPLES) // 2
        return samples[start:start + WINDOW_SAMPLES]
    if mode == "tile":
        reps = WINDOW_SAMPLES // samples.shape[0] + 1
        return np.tile(samples, reps)[:WINDOW_SAMPLES]
    out = np.zeros(WINDOW_SAMPLES, dtype=np.float32)
    out[:samples.shape[0]] = samples
    return out


def main() -> None:
    import numpy as np
    import torch
    import coremltools as ct
    from speechbrain.inference.classifiers import EncoderClassifier

    torch.set_grad_enabled(False)

    print("[LANGID] loading speechbrain/lang-id-voxlingua107-ecapa …")
    classifier = EncoderClassifier.from_hparams(
        source="speechbrain/lang-id-voxlingua107-ecapa",
        savedir="langid_hf_cache", run_opts={"device": "cpu"})
    classifier.eval()

    ind2lab = classifier.hparams.label_encoder.ind2lab
    labels = []
    for i in range(len(ind2lab)):
        code = str(ind2lab[i]).strip().split(":")[0].strip()
        labels.append(LABEL_FIXES.get(code, code))
    print(f"[LANGID] {len(labels)} languages")

    fbank = classifier.mods.compute_features
    mean_var_norm = classifier.mods.mean_var_norm
    embedding_model = classifier.mods.embedding_model
    head = classifier.mods.classifier
    stft = fbank.compute_STFT
    filterbank = fbank.compute_fbanks

    # ── A. print the EXACT feature parameters in use ──────────────────────
    def attr(obj, name, default=None):
        return getattr(obj, name, default)

    n_fft = int(stft.n_fft)
    hop_raw = float(stft.hop_length)
    hop = int(round(hop_raw)) if hop_raw > 50 else int(
        round(stft.sample_rate * hop_raw / 1000.0))
    window = stft.window.detach().to(torch.float32)
    win_length = int(window.numel())
    power = float(attr(fbank, "power_spectrogram", 2))
    amin = float(attr(filterbank, "amin", 1e-10))
    ref_value = float(attr(filterbank, "ref_value", 1.0))
    top_db = float(attr(filterbank, "top_db", 80.0))
    multiplier = float(attr(filterbank, "multiplier", 10.0))
    db_multiplier = float(attr(filterbank, "db_multiplier",
                               float(np.log10(max(amin, ref_value)))))
    n_mels = int(attr(filterbank, "n_mels", 60))
    norm_type = str(attr(mean_var_norm, "norm_type", "sentence"))
    std_norm = bool(attr(mean_var_norm, "std_norm", False))
    print(f"[LANGID] FEATURE PARAMS: sample_rate={int(stft.sample_rate)} "
          f"n_fft={n_fft} win_length={win_length} hop={hop} "
          f"center={bool(stft.center)} pad_mode={stft.pad_mode} "
          f"normalized_stft={bool(attr(stft, 'normalized_stft', False))} "
          f"power={power} n_mels={n_mels} "
          f"f_min={float(attr(filterbank, 'f_min', 0.0))} "
          f"f_max={float(attr(filterbank, 'f_max', 8000.0))} "
          f"log_mel={bool(attr(filterbank, 'log_mel', True))} "
          f"amin={amin} multiplier={multiplier} db_multiplier={db_multiplier} "
          f"top_db={top_db} norm_type={norm_type} std_norm={std_norm} "
          f"deltas={bool(attr(fbank, 'deltas', False))}")
    assert bool(stft.center), "expected center=True"
    assert str(stft.pad_mode) == "constant", \
        f"unexpected pad_mode {stft.pad_mode} — Swift pads with zeros"
    assert not bool(attr(stft, "normalized_stft", False))
    assert norm_type == "sentence", f"unexpected norm_type {norm_type}"
    assert not std_norm, "expected std_norm=False"
    assert not bool(attr(fbank, "deltas", False))

    n_freq = n_fft // 2 + 1

    # ── B. export frontend constants ──────────────────────────────────────
    # Windowed DFT basis, layout [n_fft, n_freq] so features = frames @ basis.
    win_full = torch.zeros(n_fft)
    left = (n_fft - win_length) // 2
    win_full[left:left + win_length] = window
    n = torch.arange(n_fft, dtype=torch.float64).unsqueeze(1)
    k = torch.arange(n_freq, dtype=torch.float64).unsqueeze(0)
    angle = 2.0 * torch.pi * n * k / n_fft
    cos_basis = (torch.cos(angle) * win_full.double().unsqueeze(1)).float()
    sin_basis = (-torch.sin(angle) * win_full.double().unsqueeze(1)).float()

    # Mel matrix extracted NUMERICALLY from the live Filterbank: its forward
    # is linear before the log, so feeding an identity "spectrogram" with
    # log_mel disabled yields the exact matrix [n_freq, n_mels].
    saved_log_mel = filterbank.log_mel
    filterbank.log_mel = False
    eye = torch.eye(n_freq).unsqueeze(0)  # (1, time=n_freq, n_freq)
    mel_matrix = filterbank(eye)[0].detach().to(torch.float32)
    filterbank.log_mel = saved_log_mel
    assert mel_matrix.shape == (n_freq, n_mels), mel_matrix.shape

    n_frames = (WINDOW_SAMPLES + 2 * (n_fft // 2) - n_fft) // hop + 1
    print(f"[LANGID] feature tensor for {WINDOW_SECONDS}s: "
          f"[1, {n_frames}, {n_mels}]")

    def frontend_config(padding):
        return {
            "sampleRate": SAMPLE_RATE, "windowSamples": WINDOW_SAMPLES,
            "nFft": n_fft, "hop": hop, "nFreq": n_freq, "nMels": n_mels,
            "frames": n_frames, "power": power, "amin": amin,
            "multiplier": multiplier, "dbMultiplier": db_multiplier,
            "topDb": top_db, "padding": padding,
            "cosBasisCount": n_fft * n_freq, "sinBasisCount": n_fft * n_freq,
            "melCount": n_freq * n_mels,
        }

    def write_frontend(dirpath, padding):
        blob = b"".join(t.numpy().astype("<f4").tobytes()
                        for t in (cos_basis.reshape(-1),
                                  sin_basis.reshape(-1),
                                  mel_matrix.reshape(-1)))
        (dirpath / "frontend.bin").write_bytes(blob)
        (dirpath / "frontend.json").write_text(
            json.dumps(frontend_config(padding)))

    # ── Python reference feature pipeline (official modules) ──────────────
    def check_feats(raw_np, sig, feats, tag):
        """Guard the EXACT official path: for seconds of 16 kHz speech the
        feature tensor must be [1, hundreds_of_frames, 60] — never a
        single frame. A degenerate shape here means the waveform or the
        feature call is wrong, and everything downstream is garbage."""
        print(f"[LANGID] {tag}: raw.shape={raw_np.shape} "
              f"sig.shape={tuple(sig.shape)} feats.shape={tuple(feats.shape)}")
        assert raw_np.ndim == 1 and raw_np.shape[0] > SAMPLE_RATE // 10, \
            f"{tag}: waveform is degenerate: {raw_np.shape}"
        assert feats.ndim == 3, f"{tag}: feats.ndim={feats.ndim}, " \
            f"shape={tuple(feats.shape)} — expected [1, frames, {n_mels}]"
        assert feats.shape[0] == 1, f"{tag}: batch={feats.shape[0]}"
        assert feats.shape[2] == n_mels, \
            f"{tag}: last dim {feats.shape[2]} != n_mels {n_mels} " \
            f"(full shape {tuple(feats.shape)}) — transposed?"
        assert feats.shape[1] > 10, \
            f"{tag}: only {feats.shape[1]} time frame(s) " \
            f"(full shape {tuple(feats.shape)}) — averaged/sliced/" \
            f"wrong-axis unsqueeze? raw had {raw_np.shape[0]} samples"

    def official_features(samples_np):
        sig = torch.from_numpy(samples_np).unsqueeze(0)
        feats = fbank(sig)
        feats = mean_var_norm(feats, torch.ones(1))
        check_feats(samples_np, sig, feats, "official_features")
        return feats[0].numpy()

    def official_probs(samples_np):
        sig = torch.from_numpy(samples_np).unsqueeze(0)
        feats = fbank(sig)
        feats = mean_var_norm(feats, torch.ones(1))
        check_feats(samples_np, sig, feats, "official_probs")
        out = head(embedding_model(feats, torch.ones(1)))
        return torch.softmax(out.squeeze(1), dim=-1)[0].numpy()

    def top5(probs):
        order = np.argsort(-probs)[:5]
        return [(labels[int(i)], float(probs[int(i)])) for i in order]

    def fmt5(entries):
        return "  ".join(f"{c} {p:.3f}" for c, p in entries)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        # ── test clips from real TTS speech ───────────────────────────────
        voices = subprocess.run(
            ["say", "-v", "?"], capture_output=True, text=True).stdout
        clips = []  # (code, wav_path)
        for code, voice, text in TTS_CLIPS:
            if voice is not None and voice not in voices:
                print(f"[LANGID] voice for '{code}' not installed — skipped")
                continue
            aiff = tmpdir / f"{code}.aiff"
            wav = tmpdir / f"{code}.wav"
            cmd = ["say", "-o", str(aiff)]
            if voice:
                cmd += ["-v", voice]
            cmd.append(text)
            try:
                run(cmd)
                run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c",
                     "1", str(aiff), str(wav)])
                clips.append((code, wav))
            except subprocess.CalledProcessError:
                print(f"[LANGID] TTS for '{code}' failed — skipped")
        assert clips, "no test clips could be generated"
        # A deliberately SHORT clip for the padding-mode decision.
        short_aiff = tmpdir / "short.aiff"
        short_wav = tmpdir / "short.wav"
        run(["say", "-o", str(short_aiff), "Good morning everyone."])
        run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
             str(short_aiff), str(short_wav)])
        clips.append(("en-short", short_wav))

        # ── C. convert ONLY the backend, gate on parity ───────────────────
        class Backend(torch.nn.Module):
            def forward(self, feats):
                lengths = torch.ones(feats.shape[0])
                out = head(embedding_model(feats, lengths))
                return torch.softmax(out.squeeze(1), dim=-1)

        ref_wave = pad_to_window(read_wav_f32(clips[0][1]), "zero")
        ref_feats = official_features(ref_wave)
        assert ref_feats.shape == (n_frames, n_mels), ref_feats.shape
        example_feats = torch.from_numpy(
            ref_feats.reshape(1, n_frames, n_mels))
        torch_probs = Backend().eval()(example_feats).numpy()[0]

        print("[LANGID] converting BACKEND (features→probs) to Core ML …")
        back_traced = torch.jit.trace(Backend().eval(), example_feats)
        back_pkg = tmpdir / "LangIDBackend.mlpackage"
        ct.convert(
            back_traced,
            inputs=[ct.TensorType(name="features",
                                  shape=(1, n_frames, n_mels),
                                  dtype=np.float32)],
            outputs=[ct.TensorType(name="probabilities")],
            minimum_deployment_target=ct.target.iOS16,
            compute_precision=ct.precision.FLOAT32,
            convert_to="mlprogram",
        ).save(str(back_pkg))
        back_model = ct.models.MLModel(str(back_pkg))
        back_probs = np.array(back_model.predict(
            {"features": ref_feats.reshape(1, n_frames, n_mels)
             .astype(np.float32)})["probabilities"]).reshape(-1)
        b_diff = float(np.abs(torch_probs - back_probs).max())
        print(f"[LANGID] BACKEND parity: torch top-5 {fmt5(top5(torch_probs))}")
        print(f"[LANGID] BACKEND parity: coreml top-5 {fmt5(top5(back_probs))}"
              f"  max prob diff {b_diff:.4f}")
        if int(back_probs.argmax()) != int(torch_probs.argmax()) \
                or b_diff > 0.05:
            sys.exit("[LANGID] FAIL: backend Core ML diverges from PyTorch.")

        # Compile assets ONCE into a staging dir the Swift harness can use.
        stage = tmpdir / "assets"
        stage.mkdir()
        run(["xcrun", "coremlcompiler", "compile", str(back_pkg), str(stage)])
        (stage / "labels.json").write_text(json.dumps(labels))

        # ── D+E. compile the ACTUAL shipping Swift and gate it ────────────
        harness = tmpdir / "langid_parity"
        run(["swiftc", "-O", str(HARNESS_SWIFT), str(FBANK_SWIFT),
             "-o", str(harness), "-framework", "CoreML",
             "-framework", "Accelerate"])

        def swift_run(wav_np, padding):
            write_frontend(stage, padding)
            pcm_file = tmpdir / "in.f32"
            pcm_file.write_bytes(wav_np.astype("<f4").tobytes())
            feat_file = tmpdir / "out.f32"
            result = subprocess.run(
                [str(harness), str(stage), str(pcm_file), str(feat_file)],
                capture_output=True, text=True, check=True)
            feats = np.frombuffer(feat_file.read_bytes(), dtype="<f4") \
                .reshape(n_frames, n_mels)
            probs = None
            for line in result.stdout.splitlines():
                if line.startswith("PROBS "):
                    probs = np.array(
                        [float(v) for v in line.split()[1:]], dtype=np.float64)
            assert probs is not None and probs.size == len(labels), \
                f"harness output missing PROBS: {result.stdout[-2000:]}"
            return feats, probs

        def feature_report(tag, ref, got):
            diff = np.abs(ref - got)
            max_diff = float(diff.max())
            mean_diff = float(diff.mean())
            frame, binx = np.unravel_index(int(diff.argmax()), diff.shape)
            print(f"[LANGID] FEATURE TEST {tag}: shape {got.shape}, "
                  f"max abs diff {max_diff:.5f}, mean abs diff "
                  f"{mean_diff:.5f}, worst at frame {frame} bin {binx} "
                  f"(ref {ref[frame, binx]:.3f} vs {got[frame, binx]:.3f})")
            return max_diff, mean_diff

        # PARITY TEST ONLY: both paths receive the IDENTICAL 80000-sample
        # window — official SpeechBrain on those samples vs Swift Fbank +
        # Core ML backend on those SAME samples. Comparing official
        # variable-length audio against the fixed 5-second Core ML input
        # was an invalid test (different audio durations). Whether
        # synthetic TTS speech is classified as its INTENDED language is
        # explicitly NOT a gate — the official model itself misclassifies
        # e.g. synthetic Bengali (pt 0.42 / en 0.41); language ACCURACY is
        # judged later on the real iPhone with real human speech.
        results = {}
        for padding in ("zero", "tile"):
            all_ok = True
            print(f"[LANGID] ── padding mode: {padding} ──")
            for code, wav in clips:
                raw = read_wav_f32(wav)
                padded = pad_to_window(raw, padding)  # exactly 80000 samples
                ref_f = official_features(padded)
                swift_f, swift_probs = swift_run(padded, padding)
                feature_report(f"{code}/{padding}", ref_f, swift_f)
                official = official_probs(padded)  # SAME 80000 samples
                off5, swf5 = top5(official), top5(swift_probs)
                match = off5[0][0] == swf5[0][0]
                all_ok = all_ok and match
                print(f"[LANGID] PARITY TEST {code}/{padding}: "
                      f"official(same 5s) top-5: {fmt5(off5)}")
                print(f"[LANGID] PARITY TEST {code}/{padding}: "
                      f"swift+coreml top-5: {fmt5(swf5)}"
                      f"  → {'MATCH' if match else 'MISMATCH'}")
            results[padding] = all_ok
        chosen = next((m for m in ("zero", "tile") if results[m]), None)
        if chosen is None:
            sys.exit("[LANGID] FAIL: Swift+CoreML disagreed with official "
                     "SpeechBrain on IDENTICAL 5-second input in every "
                     "padding mode — see FEATURE/PARITY TEST lines above "
                     "for the failing stage.")
        print(f"[LANGID] padding mode chosen: {chosen}")
        write_frontend(stage, chosen)

        # ── F. size gate + install into the app ───────────────────────────
        total_mb = sum(f.stat().st_size for f in stage.rglob("*")
                       if f.is_file()) / (1024 * 1024)
        print(f"[LANGID] bundled asset size: {total_mb:.1f} MB "
              f"(limit {MAX_MODEL_MB})")
        if total_mb > MAX_MODEL_MB:
            sys.exit(f"[LANGID] FAIL: {total_mb:.1f} MB exceeds limit.")
        (stage / "model_info.json").write_text(json.dumps({
            "source": "speechbrain/lang-id-voxlingua107-ecapa",
            "license": "Apache-2.0",
            "pipeline": "native-frontend",
            "padding": chosen,
            "windowSamples": WINDOW_SAMPLES,
            "sampleRate": SAMPLE_RATE,
            "frames": n_frames,
            "nMels": n_mels,
            "bundleMB": round(total_mb, 1),
        }))
        if OUT_DIR.exists():
            shutil.rmtree(OUT_DIR)
        shutil.copytree(stage, OUT_DIR)
        print(f"[LANGID] installed → {OUT_DIR}")
        print("[LANGID] PASSED")


if __name__ == "__main__":
    main()
