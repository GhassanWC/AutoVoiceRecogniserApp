import 'dart:typed_data';

import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

import 'local_language_detect.dart';

/// One recognized utterance from the on-device recognizer.
class LocalTranscript {
  const LocalTranscript({required this.text, required this.language});
  final String text;

  /// ISO 639-1 code Whisper detected (backed up by script analysis), or "und".
  final String language;
}

/// Abstract so the pipeline and tests never touch the native plugin directly.
abstract class LocalSpeechEngine {
  Future<void> load(String modelPath);
  bool get isLoaded;

  /// Transcribes one PCM16LE mono 16 kHz utterance. Language is auto-detected
  /// per utterance — never configured (the room may switch languages freely).
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate);

  Future<void> dispose();
}

/// whisper.cpp via the whisper_cpp_flutter_plus plugin (MIT; models are the
/// user-downloaded multilingual ggml weights — NEVER .en variants).
///
/// This is the ONLY file that touches the plugin API, so a plugin upgrade or
/// API drift is contained here.
class WhisperLocalSpeechEngine implements LocalSpeechEngine {
  WhisperEngine? _engine;

  /// whisper.cpp build identification, for load-failure diagnostics.
  static String get nativeVersion => WhisperEngine.version;
  static String get nativeSystemInfo => WhisperEngine.systemInfo;

  @override
  bool get isLoaded => _engine != null;

  @override
  Future<void> load(String modelPath) async {
    if (_engine != null) return;
    _engine = await WhisperEngine.load(modelPath);
  }

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Whisper model not loaded');
    }
    // PCM16LE → normalized float samples, as whisper.cpp expects.
    final data = ByteData.sublistView(pcm16);
    final samples = Float32List(pcm16.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final task = engine.transcribe(
      samples,
      options: const TranscribeOptions(language: 'auto'),
    );
    final result = await task.result;
    final text = result.text.trim();

    // Whisper reports the detected language; script analysis backs it up
    // (and can only ever refine unique-script text, e.g. Urdu vs Arabic).
    String language = 'und';
    final reported = result.language.toLowerCase();
    if (reported.length >= 2 && reported != 'auto') {
      language = reported.substring(0, 2);
    }
    final byScript = detectLanguageByScript(text);
    if (byScript != null) language = byScript;

    return LocalTranscript(text: text, language: language);
  }

  @override
  Future<void> dispose() async {
    _engine?.dispose();
    _engine = null;
  }
}
