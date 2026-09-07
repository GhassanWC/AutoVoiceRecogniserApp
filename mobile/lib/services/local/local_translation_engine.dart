/// Phase B slot: fully on-device translation.
///
/// Plan (do not ship FP32 weights):
///  - Model: facebook/m2m100_418M (MIT, ~100 languages, any→any) — ONE
///    downloadable multilingual model instead of dozens of pairs.
///  - Quantize to INT8 (dynamic quantization of the linear layers gets the
///    1.94 GB FP32 checkpoint to roughly 450–550 MB) and export twice:
///      a) Core ML program (encoder + decoder with KV-cache, ANE-friendly),
///      b) ONNX Runtime Mobile (ort format, XNNPACK/CoreML EP).
///    Benchmark both on the target iPhone for tokens/sec, RAM and thermal
///    load; ship whichever wins. Tokenizer: SentencePiece model (~2.4 MB)
///    joins the offline model catalog and checksum flow.
///  - Greedy or beam-1 decoding first (latency over polish), target-language
///    forced BOS token per M2M100's convention.
///
/// Phase A intentionally ships [PassthroughLocalTranslator]: same-language
/// utterances (the Arabic→Arabic acceptance case) pass through unchanged and
/// everything else surfaces the source transcript, so on-device Whisper can
/// be validated on a real iPhone before any translation model lands.
abstract class LocalTranslator {
  /// Returns translated text, or null when this translator cannot translate
  /// the pair (Phase A: any cross-language request).
  Future<String?> translate({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  });
}

class PassthroughLocalTranslator implements LocalTranslator {
  const PassthroughLocalTranslator();

  @override
  Future<String?> translate({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    // Source equals target → the text is already what the user reads.
    if (sourceLanguage == targetLanguage) return text;
    return null; // cross-language translation arrives with M2M100 in Phase B
  }
}
