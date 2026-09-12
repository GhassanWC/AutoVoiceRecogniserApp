import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../../utils/languages.dart';
import '../local/local_speech_engine.dart';
import 'language_id.dart';

/// The PRODUCTION on-device speech engine (Phase 3): the user never picks a
/// source language — every utterance goes through the proven Phase-1/2
/// chain:
///
///   utterance PCM → AudioLanguageDetector (VoxLingua107 Core ML)
///     → AppleSpeechLocaleResolver → exactly ONE Apple recognizer
///     → source transcript + detected language
///
/// Detection runs again for EVERY utterance — the session is never locked
/// to the first detected language. The detector model is warmed once at
/// Start Listening and reused for the whole session (never reloaded per
/// utterance).
class DetectingSpeechEngine implements LocalSpeechEngine {
  static const MethodChannel _channel = MethodChannel('app.livetranslator/langid');

  /// Minimum detector confidence before an utterance is trusted. Deliberately
  /// LENIENT: real-iPhone Phase-1/2 tests showed correct detections well
  /// above this, and an overly aggressive threshold would silently eat
  /// speech. Tune from session [LANG-ID] logs, which always show the top
  /// candidates.
  static const double confidenceThreshold = 0.40;

  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  /// [languages] is ignored — source language is AUTOMATIC. Warms the
  /// detector model so per-utterance latency never includes a model load.
  @override
  Future<void> load(List<String> languages) async {
    try {
      await _channel.invokeMethod<void>('warmup')
          .timeout(const Duration(seconds: 20));
      _loaded = true;
    } on MissingPluginException {
      throw StateError(
          'Automatic language detection is only available on iOS in this build.');
    } on PlatformException catch (error) {
      throw StateError('${error.message}');
    } on TimeoutException {
      throw StateError('The language detector did not answer within 20s.');
    }
  }

  @override
  Future<LocalTranscript> transcribe(Uint8List pcm16, int sampleRate) async {
    if (!_loaded) throw StateError('Detector not warmed up');
    final outcome = await AudioLanguageId.detectAndTranscribe(pcm16);
    final name = languageForCode(outcome.language)?.name ?? outcome.language;
    final alternatives = outcome.alternatives
        .map((alt) => '${alt.$1} ${alt.$2.toStringAsFixed(2)}')
        .join('  ');
    developer.log(
      '[LANG-ID] ${outcome.language} '
      'confidence=${outcome.confidence.toStringAsFixed(2)} '
      'latency=${outcome.detectionMs}ms  top: $alternatives',
      name: 'local',
    );

    if (outcome.confidence < confidenceThreshold) {
      return const LocalTranscript(
        text: '',
        language: 'und',
        discardNotice: "Couldn't identify the spoken language.",
      );
    }
    if (!outcome.speechAvailable) {
      return LocalTranscript(
        text: '',
        language: outcome.language,
        discardNotice: "$name was detected, but speech recognition isn't "
            'available for it on this device.',
      );
    }
    if (outcome.speechError != null) {
      developer.log(
        '[SPEECH] locale=${outcome.locale} backend=${outcome.backend} '
        'FAILED after ${outcome.speechMs}ms: ${outcome.speechError}',
        name: 'local',
      );
      return LocalTranscript(
        text: '',
        language: outcome.language,
        discardNotice: "Couldn't transcribe that — try again.",
      );
    }
    developer.log(
      '[SPEECH] locale=${outcome.locale} backend=${outcome.backend} '
      'latency=${outcome.speechMs}ms',
      name: 'local',
    );
    final text = outcome.text?.trim() ?? '';
    developer.log('[SPEECH] text="$text"', name: 'local');
    return LocalTranscript(text: text, language: outcome.language);
  }

  @override
  Future<void> dispose() async {
    _loaded = false;
  }
}
