import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

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

  /// Acceptance rule = confidence TOGETHER WITH the separation between the
  /// two best candidates — never a blind absolute threshold. A dominant
  /// top-1 (en 0.34 vs cy 0.05) is a strong identification even below 0.40;
  /// a photo finish (en 0.27 vs de 0.25) is genuinely ambiguous. These are
  /// PERMISSIVE debug values for the TestFlight measurement build — tune
  /// from real session [LANG-ID] logs, which always print top1/top2/margin.
  static const double minTop1Confidence = 0.20;
  static const double minMargin = 0.10;

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

    // THE shared preparation path (same function as the developer tests).
    final prepared = prepareLanguageIdAudio(pcm16);

    // [LIVE-AUDIO]: exactly what the detector receives from the live VAD.
    final samples = prepared.length ~/ 2;
    final data = ByteData.sublistView(prepared);
    var peak = 0;
    var sumSquares = 0.0;
    for (var i = 0; i < samples; i++) {
      final s = data.getInt16(i * 2, Endian.little);
      if (s.abs() > peak) peak = s.abs();
      sumSquares += (s / 32768.0) * (s / 32768.0);
    }
    final rms = samples == 0 ? 0.0 : math.sqrt(sumSquares / samples);
    developer.log(
      '[LIVE-AUDIO] samples=$samples '
      'durationMs=${(samples * 1000 / sampleRate).round()} '
      'rms=${rms.toStringAsFixed(4)} peak=$peak/32767',
      name: 'local',
    );

    final outcome = await AudioLanguageId.detectAndTranscribe(prepared);
    final name = languageForCode(outcome.language)?.name ?? outcome.language;
    final top1 = outcome.confidence;
    final top2 =
        outcome.alternatives.length > 1 ? outcome.alternatives[1].$2 : 0.0;
    final top2Code =
        outcome.alternatives.length > 1 ? outcome.alternatives[1].$1 : '-';
    final margin = top1 - top2;
    developer.log(
      '[LANG-ID] top1=${outcome.language} '
      'confidence=${top1.toStringAsFixed(2)} '
      'top2=$top2Code ${top2.toStringAsFixed(2)} '
      'margin=${margin.toStringAsFixed(2)} '
      'latency=${outcome.detectionMs}ms',
      name: 'local',
    );

    final ambiguous = top1 < minTop1Confidence || margin < minMargin;
    if (ambiguous) {
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
