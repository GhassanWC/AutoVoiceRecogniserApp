import 'dart:async';

import 'package:flutter/services.dart';

import 'local_language_detect.dart';

/// One recognized utterance from the on-device recognizer.
class LocalTranscript {
  const LocalTranscript({
    required this.text,
    required this.language,
    this.discardNotice,
  });

  final String text;

  /// ISO 639-1 code the platform detected (backed up by script analysis),
  /// or "und" for silence/non-speech.
  final String language;

  /// Non-null when this utterance should NOT become a chat bubble — e.g.
  /// the language couldn't be identified confidently, or Apple has no
  /// recognizer for the detected language. The pipeline discards the
  /// pending bubble and surfaces this short user-facing message subtly.
  final String? discardNotice;
}

/// Abstract so the pipeline and tests never touch the native bridge directly.
abstract class LocalSpeechEngine {
  /// [languages] are the SOURCE languages the user selected to listen for.
  /// One language is valid (single-recognizer fast path); with several, each
  /// utterance is auto-detected among exactly these — never among every
  /// language installed on the phone.
  Future<void> load(List<String> languages);
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

  /// Pins the native detection set to the user's selected [languages]
  /// (those already installed; downloads are NativeSpeechAssets' job).
  /// Pre-iOS 26 this also triggers the speech authorization dialog.
  @override
  Future<void> load(List<String> languages) async {
    // Always re-prepare: the user's selection may have changed since the
    // last session, and prepare is a cheap inventory check natively.
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>(
        'prepare',
        {'languages': languages},
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
