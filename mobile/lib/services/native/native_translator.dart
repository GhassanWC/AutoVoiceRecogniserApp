import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import '../local/local_translation_engine.dart';

/// The phone's OWN on-device translation (Apple Translation framework on
/// iOS; ML Kit on Android when its pipeline lands) behind
/// `app.livetranslator/translate`.
///
/// Language packs are downloaded by the PLATFORM's mechanism (Apple's
/// prepareTranslation sheet) — a missing pack is a pending download, never
/// treated as an error by itself.
class NativeOnDeviceTranslator implements LocalTranslator {
  static const MethodChannel _channel =
      MethodChannel('app.livetranslator/translate');

  /// Triggers the platform's language-pack download flow for [target]
  /// (source auto-detect pair). Safe to call every session start: an
  /// already-installed pack returns immediately. Never throws — a failed
  /// prepare only means the first translation may prompt/download instead.
  static Future<void> prepare({required String targetLanguage}) async {
    try {
      await _channel.invokeMethod<void>(
        'prepare',
        {'to': targetLanguage},
      ).timeout(const Duration(minutes: 3));
    } catch (error) {
      developer.log('[TRANSLATE] prepare failed: $error', name: 'translate');
    }
  }

  @override
  Future<String?> translate({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    // Same language → the text is already what the user reads (ar→ar case).
    if (sourceLanguage == targetLanguage) return text;
    // Unknown source: let the platform auto-detect (Apple supports a nil
    // source); "und" from silence never reaches here (pipeline skips empty).
    final from = sourceLanguage == 'und' ? null : sourceLanguage;
    final started = DateTime.now();
    try {
      final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
        'translate',
        {'text': text, 'from': from, 'to': targetLanguage},
      ).timeout(const Duration(seconds: 30));
      final translated = (reply?['text'] as String? ?? '').trim();
      developer.log(
        '[TRANSLATE] $sourceLanguage → $targetLanguage '
        'latency=${DateTime.now().difference(started).inMilliseconds}ms',
        name: 'local',
      );
      return translated.isEmpty ? null : translated;
    } catch (error) {
      // null → the bubble shows the transcript with a Retry action; the
      // developer log carries the exact platform error.
      developer.log(
        '[TRANSLATE] $sourceLanguage→$targetLanguage failed: $error',
        name: 'translate',
      );
      return null;
    }
  }
}
