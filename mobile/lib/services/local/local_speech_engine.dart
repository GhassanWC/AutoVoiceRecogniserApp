import 'dart:async';

import 'package:flutter/services.dart';

import 'local_language_detect.dart';

/// One recognized utterance from the on-device recognizer.
class LocalTranscript {
  const LocalTranscript({required this.text, required this.language});
  final String text;

  /// ISO 639-1 code Whisper detected (backed up by script analysis), or "und".
  final String language;
}

/// Abstract so the pipeline and tests never touch the native bridge directly.
abstract class LocalSpeechEngine {
  /// [model] is the engine's model identifier — for WhisperKit, the Core ML
  /// variant name (downloaded + cached natively on first load).
  Future<void> load(String model);
  bool get isLoaded;

  /// Transcribes one PCM16LE mono 16 kHz utterance. Language is auto-detected
  /// per utterance — never configured (the room may switch languages freely).
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate);

  Future<void> dispose();
}

/// WhisperKit (Swift-native, Core ML, MIT) through the
/// `app.livetranslator/whisperkit` MethodChannel in AppDelegate.swift.
///
/// This replaced the whisper.cpp FFI plugin after its native model loader
/// crashed the process on real iPhones (uncaught C++ exceptions across the
/// FFI boundary → SIGABRT). A Swift bridge fails as a catchable
/// PlatformException instead — the app can never be killed by a load again.
///
/// This is the ONLY file that touches the bridge API, so any change to the
/// native side is contained here.
class WhisperKitSpeechEngine implements LocalSpeechEngine {
  static const MethodChannel _channel =
      MethodChannel('app.livetranslator/whisperkit');

  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  /// Loads the CI-BUNDLED WhisperKit model [model] (a variant name from the
  /// catalog, e.g. "openai_whisper-small"). Strictly local: the native side
  /// initializes with download:false from the app bundle and enforces a hard
  /// 30 s timeout; the Dart timeout below is only a backstop so a
  /// never-replying channel can't hang the UI either.
  @override
  Future<void> load(String model) async {
    if (_loaded) return;
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>(
        'load',
        {'variant': model},
      ).timeout(const Duration(seconds: 40));
      _loaded = true;
    } on MissingPluginException {
      throw StateError(
          'On-device recognition is only available on iOS in this build.');
    } on TimeoutException {
      throw StateError(
          'WhisperKit did not answer within 40s (native 30s timeout also '
          'missing) — model initialization is wedged.');
    }
  }

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) async {
    if (!_loaded) {
      throw StateError('WhisperKit model not loaded');
    }
    final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
      'transcribe',
      {'pcm16': pcm16, 'sampleRate': sampleRate},
    );
    final text = (reply?['text'] as String? ?? '').trim();

    // WhisperKit reports the detected language; script analysis backs it up
    // (and can only ever refine unique-script text, e.g. Urdu vs Arabic).
    String language = 'und';
    final reported = (reply?['language'] as String? ?? '').toLowerCase();
    if (reported.length >= 2 && reported != 'auto') {
      language = reported.substring(0, 2);
    }
    final byScript = detectLanguageByScript(text);
    if (byScript != null) language = byScript;

    return LocalTranscript(text: text, language: language);
  }

  @override
  Future<void> dispose() async {
    _loaded = false;
    try {
      await _channel.invokeMethod<void>('unload');
    } on MissingPluginException {
      // Non-iOS platform — nothing was loaded natively.
    }
  }
}
