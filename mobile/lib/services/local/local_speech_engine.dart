import 'dart:async';

import 'package:flutter/services.dart';

import 'local_language_detect.dart';

/// One recognized utterance from the on-device recognizer.
class LocalTranscript {
  const LocalTranscript({required this.text, required this.language});
  final String text;

  /// ISO 639-1 code the platform detected (backed up by script analysis),
  /// or "und" for silence/non-speech.
  final String language;
}

/// Abstract so the pipeline and tests never touch the native bridge directly.
abstract class LocalSpeechEngine {
  /// [model] is engine-specific configuration — for the native platform
  /// engine it is the TARGET language code (the detection set derives from
  /// the product languages + target on the native side).
  Future<void> load(String model);
  bool get isLoaded;

  /// Transcribes one PCM16LE mono 16 kHz utterance. Language is auto-detected
  /// per utterance — never configured (the room may switch languages freely).
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate);

  Future<void> dispose();
}

/// The phone's OWN speech recognition (production on-device path):
/// on iOS, per-utterance parallel on-device SFSpeechRecognizer across the
/// product language set, scored natively for language auto-detection
/// (Apple's recognizers are locale-fixed, so detection is built from
/// parallel recognition — the capability probe gates devices honestly).
///
/// Utterances still come from the app's UNCHANGED environmental capture +
/// VAD; this engine never opens the microphone itself. This is the ONLY
/// file that touches the bridge API.
class NativeSpeechEngine implements LocalSpeechEngine {
  static const MethodChannel _channel =
      MethodChannel('app.livetranslator/nativestt');

  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  /// [model] = target language code. Requests speech-recognition
  /// authorization (first run shows the OS dialog) and pins the detection
  /// set to what this device supports on-device.
  @override
  Future<void> load(String model) async {
    if (_loaded) return;
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>(
        'prepare',
        {'targetLanguage': model},
      ).timeout(const Duration(seconds: 30));
      _loaded = true;
    } on MissingPluginException {
      throw StateError(
          'Native on-device recognition is not available on this platform yet.');
    } on TimeoutException {
      throw StateError('Speech recognition setup did not answer within 30s.');
    }
  }

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) async {
    if (!_loaded) {
      throw StateError('Native speech engine not prepared');
    }
    final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
      'recognize',
      {'pcm16': pcm16, 'sampleRate': sampleRate},
    ).timeout(const Duration(seconds: 25));
    final text = (reply?['text'] as String? ?? '').trim();

    // The native side reports the detected language; script analysis backs
    // it up (and can only ever refine unique-script text, e.g. Urdu vs Arabic).
    String language = 'und';
    final reported = (reply?['language'] as String? ?? '').toLowerCase();
    if (reported.length >= 2 && reported != 'auto' && reported != 'und') {
      language = reported.substring(0, 2);
    }
    final byScript = detectLanguageByScript(text);
    if (byScript != null) language = byScript;

    return LocalTranscript(text: text, language: language);
  }

  @override
  Future<void> dispose() async {
    _loaded = false;
  }
}
