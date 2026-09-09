import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The answer to "can THIS device run the full Live Translator experience
/// with the platform's own on-device speech + translation?" — built from the
/// actual OS capability APIs, never from an OS-version number alone.
///
/// The full experience means: the user picks ONLY the target language;
/// sources are auto-detected per utterance. A device that could merely do a
/// fixed-pair translator is reported as NOT supported rather than silently
/// shrinking the product.
class LiveTranslationSupport {
  const LiveTranslationSupport({
    required this.supported,
    required this.reason,
    required this.osVersion,
    required this.speechSupported,
    required this.languageDetectionSupported,
    required this.translationSupported,
    required this.updateRequired,
    this.availableLanguages = const [],
    this.readyLanguages = const [],
    this.pendingDownloads = const [],
    this.missingLanguages = const [],
    this.languageStatus = const {},
    this.translationPairs = const {},
    this.speechDiagnostics = const [],
  });

  final bool supported;

  /// Human-readable explanation (shown in Settings and the unsupported alert).
  final String reason;
  final String osVersion;
  final bool speechSupported;
  final bool languageDetectionSupported;
  final bool translationSupported;

  /// True when an OS UPDATE could fix it — the alert must then say "Update
  /// required", never that the phone is permanently unsupported.
  final bool updateRequired;

  /// Product languages Apple/Google SUPPORT on this device (installed or
  /// downloadable). A not-yet-downloaded model is NEVER "unsupported".
  final List<String> availableLanguages;

  /// Subset of [availableLanguages] whose speech model is installed now.
  final List<String> readyLanguages;

  /// Supported languages whose speech model still needs downloading
  /// (Settings offers "Prepare Live Translation" for these).
  final List<String> pendingDownloads;

  /// Languages Apple/Google do not offer on this device at all.
  final List<String> missingLanguages;

  /// language code → "ready" | "downloadRequired" | "unsupported".
  final Map<String, String> languageStatus;

  /// Raw probe evidence (supportedLocales= / installedLocales= /
  /// reservedLocales= / maximumReservedLocales= on iOS 26).
  final List<String> speechDiagnostics;

  /// source language → translation-pack status ("installed" / "downloadable"
  /// / "unsupported"). "downloadable" is NOT an error — just a pending pack.
  final Map<String, String> translationPairs;

  /// Speech works but detection/translation doesn't → the partial-support
  /// wording is used instead of the generic one.
  bool get partiallySupported =>
      !supported &&
      speechSupported &&
      (!languageDetectionSupported || !translationSupported);

  static LiveTranslationSupport unsupportedPlatform() =>
      const LiveTranslationSupport(
        supported: false,
        reason: 'On-device Live Translation is available on iPhone and '
            'Android phones only.',
        osVersion: 'unknown',
        speechSupported: false,
        languageDetectionSupported: false,
        translationSupported: false,
        updateRequired: false,
      );

  static LiveTranslationSupport fromMap(Map<Object?, Object?> map) =>
      LiveTranslationSupport(
        supported: map['supported'] == true,
        reason: '${map['reason'] ?? 'Unknown'}',
        osVersion: '${map['osVersion'] ?? 'unknown'}',
        speechSupported: map['speechSupported'] == true,
        languageDetectionSupported: map['languageDetectionSupported'] == true,
        translationSupported: map['translationSupported'] == true,
        updateRequired: map['updateRequired'] == true,
        availableLanguages: [
          for (final code in map['availableLanguages'] as List<Object?>? ?? []) '$code'
        ],
        readyLanguages: [
          for (final code in map['readyLanguages'] as List<Object?>? ?? []) '$code'
        ],
        pendingDownloads: [
          for (final code in map['pendingDownloads'] as List<Object?>? ?? []) '$code'
        ],
        missingLanguages: [
          for (final code in map['missingLanguages'] as List<Object?>? ?? []) '$code'
        ],
        languageStatus: {
          for (final entry
              in (map['languageStatus'] as Map<Object?, Object?>? ?? {}).entries)
            '${entry.key}': '${entry.value}'
        },
        translationPairs: {
          for (final entry
              in (map['translationPairs'] as Map<Object?, Object?>? ?? {}).entries)
            '${entry.key}': '${entry.value}'
        },
        speechDiagnostics: [
          for (final line in map['speechDiagnostics'] as List<Object?>? ?? []) '$line'
        ],
      );
}

/// App-wide probe cache: Settings' status row, the Start Listening gate and
/// the unsupported alert all observe the same result; "Check Again" calls
/// [refresh]. Probing NEVER throws and never crashes an unsupported device —
/// every failure degrades to an honest "not supported" result.
class LiveTranslationSupportService extends ChangeNotifier {
  static const MethodChannel _channel =
      MethodChannel('app.livetranslator/capabilities');

  LiveTranslationSupport? current;
  bool probing = false;

  /// Returns the cached result, probing first if none exists yet.
  Future<LiveTranslationSupport> ensure({required String targetLanguage}) async {
    return current ?? await refresh(targetLanguage: targetLanguage);
  }

  Future<LiveTranslationSupport> refresh({required String targetLanguage}) async {
    probing = true;
    notifyListeners();
    LiveTranslationSupport support;
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'probe',
        {'targetLanguage': targetLanguage},
      ).timeout(const Duration(seconds: 15));
      support = map == null
          ? LiveTranslationSupport.unsupportedPlatform()
          : LiveTranslationSupport.fromMap(map);
    } on MissingPluginException {
      support = LiveTranslationSupport.unsupportedPlatform();
    } catch (error) {
      support = LiveTranslationSupport(
        supported: false,
        reason: 'Could not determine device capabilities ($error). '
            'Tap Check Again to retry.',
        osVersion: 'unknown',
        speechSupported: false,
        languageDetectionSupported: false,
        translationSupported: false,
        updateRequired: false,
      );
    }
    developer.log(
      '[SUPPORT] supported=${support.supported} os=${support.osVersion} '
      'speech=${support.speechSupported} detect=${support.languageDetectionSupported} '
      'translate=${support.translationSupported} '
      'ready=${support.readyLanguages} pending=${support.pendingDownloads} '
      'reason=${support.reason}',
      name: 'support',
    );
    for (final line in support.speechDiagnostics) {
      developer.log('[SUPPORT] $line', name: 'support');
    }
    current = support;
    probing = false;
    notifyListeners();
    return support;
  }
}

/// One instance shared by the whole app.
final LiveTranslationSupportService sharedLiveTranslationSupport =
    LiveTranslationSupportService();

/// Progress snapshot for a running speech-asset installation.
class SpeechAssetInstallProgress {
  const SpeechAssetInstallProgress({
    required this.running,
    required this.language,
    required this.fraction,
    required this.completed,
    required this.total,
  });

  final bool running;
  final String? language;
  final double fraction;
  final int completed;
  final int total;
}

/// Downloads the supported-but-not-installed speech models through the
/// PLATFORM's own mechanism (AssetInventory.assetInstallationRequest →
/// downloadAndInstall on iOS 26). Used by Settings' "Prepare Live
/// Translation" and by session start when packs are pending.
class NativeSpeechAssets {
  static const MethodChannel _channel =
      MethodChannel('app.livetranslator/nativestt');

  /// Runs the installation, reporting polled progress. Throws on a real
  /// installation failure; a platform without downloadable speech assets
  /// (pre-iOS 26, Android for now) returns immediately.
  static Future<void> install({
    required String targetLanguage,
    void Function(SpeechAssetInstallProgress progress)? onProgress,
  }) async {
    final install = _channel.invokeMethod<void>(
      'installAssets',
      {'targetLanguage': targetLanguage},
    ).timeout(const Duration(minutes: 20));

    var done = false;
    unawaited(install.whenComplete(() => done = true));
    while (!done) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (onProgress == null || done) continue;
      try {
        final map =
            await _channel.invokeMethod<Map<Object?, Object?>>('installProgress');
        if (map != null) {
          onProgress(SpeechAssetInstallProgress(
            running: map['running'] == true,
            language: map['language'] as String?,
            fraction: (map['fraction'] as num?)?.toDouble() ?? 0,
            completed: (map['completed'] as num?)?.toInt() ?? 0,
            total: (map['total'] as num?)?.toInt() ?? 0,
          ));
        }
      } catch (_) {
        // Progress polling is best-effort; the install future is the truth.
      }
    }
    await install; // rethrows a real installation failure
  }
}
