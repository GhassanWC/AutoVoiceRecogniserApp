import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../audio/audio_capture_service.dart';
import '../permissions/mic_permission_service.dart';
import '../../utils/languages.dart';

/// On-device audio language identification (VoxLingua107 ECAPA via Core ML,
/// bundled at CI time — see tools/convert_langid_coreml.py). Detects the
/// SPOKEN language straight from utterance audio, BEFORE any speech
/// recognizer runs. 107 languages, ~45 MB, zero network.
class LanguageDetection {
  const LanguageDetection({
    required this.language,
    required this.confidence,
    required this.alternatives,
    required this.speechPath,
  });

  final String language;
  final double confidence;

  /// Top candidates, best first: (language code, probability).
  final List<(String, double)> alternatives;

  /// How Apple would transcribe the winner on THIS device:
  /// "transcriber:<locale>" | "onDevice:<locale>" | "network:<locale>" |
  /// "unsupported". Detection succeeding and transcription being available
  /// are two separate facts — kept separate on purpose.
  final String speechPath;
}

class AudioLanguageId {
  static const MethodChannel _channel = MethodChannel('app.livetranslator/langid');

  /// Whether the model is inside this build + its size + current Apple
  /// speech paths for the core test languages.
  static Future<Map<Object?, Object?>> status() async =>
      await _channel.invokeMethod<Map<Object?, Object?>>('status') ?? {};

  static Future<LanguageDetection> detect(Uint8List pcm16) async {
    final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
      'detect',
      {'pcm16': pcm16},
    ).timeout(const Duration(seconds: 20));
    return LanguageDetection(
      language: '${reply?['language'] ?? 'und'}',
      confidence: (reply?['confidence'] as num?)?.toDouble() ?? 0,
      alternatives: [
        for (final alt in reply?['alternatives'] as List<Object?>? ?? [])
          (
            '${(alt as Map<Object?, Object?>)['language']}',
            (alt['confidence'] as num?)?.toDouble() ?? 0,
          )
      ],
      speechPath: '${reply?['speechPath'] ?? 'unknown'}',
    );
  }
}

class LanguageIdTestReport {
  const LanguageIdTestReport({required this.passed, required this.details});
  final bool passed;
  final String details;
}

/// Settings → Developer → Test Language Detection — the ISOLATED native
/// test the new architecture is gated on: capture one spoken utterance
/// through the real environmental pipeline, run ONLY the language detector
/// (no speech recognition, no translation), and report the top candidates
/// with confidences. Run it on a real iPhone in English, Arabic, Hindi,
/// Thai and Bengali before the pipeline adopts the detector.
Future<LanguageIdTestReport> runLanguageIdTest({
  MicPermissionService? permissions,
  AudioCaptureService? capture,
  Duration speakFor = const Duration(seconds: 5),
}) async {
  final lines = <String>[];
  void log(String line) {
    lines.add(line);
    developer.log(line, name: 'langid');
  }

  LanguageIdTestReport fail(String reason) {
    log(reason);
    return LanguageIdTestReport(passed: false, details: lines.join('\n'));
  }

  log('[LANG-ID TEST — detector only, no speech recognition]');

  // 0. Model presence + Apple speech paths for the core languages.
  Map<Object?, Object?> status;
  try {
    status = await AudioLanguageId.status();
  } on MissingPluginException {
    return fail('Language identification is iOS-only in this build.');
  }
  final bundled = status['modelBundled'] == true;
  final sizeMb =
      ((status['modelBytes'] as num?)?.toDouble() ?? 0) / (1024 * 1024);
  log('Model bundled: ${bundled ? 'YES (${sizeMb.toStringAsFixed(1)} MB)' : 'NO'}');
  final speechPaths = status['speechPaths'] as Map<Object?, Object?>? ?? {};
  for (final entry in speechPaths.entries) {
    log('speech ${entry.key}=${entry.value}');
  }
  if (!bundled) {
    return fail('This build was made without the CI model-conversion step.');
  }

  // 1. Microphone permission (native truth; request only if undetermined).
  final service = permissions ?? MicPermissionService();
  var permission = await service.currentStatus();
  if (permission == MicPermissionStatus.denied) {
    permission = await service.request();
  }
  if (permission != MicPermissionStatus.granted) {
    return fail('Microphone permission is not granted '
        '(enable it in Settings → Live Translator → Microphone).');
  }

  // 2. Capture one utterance through the real environmental pipeline.
  log('Speak now — one clear sentence (${speakFor.inSeconds}s)…');
  final audio = capture ?? AudioCaptureService();
  final chunks = BytesBuilder(copy: true);
  String? stoppedReason;
  try {
    await audio.start(
      onAudio: chunks.add,
      onStopped: (reason) => stoppedReason = reason,
    );
  } on AudioCaptureUnsupportedException {
    return fail('Native audio capture is unavailable on this platform.');
  } catch (error) {
    return fail('Could not start the microphone: $error');
  }
  await Future<void>.delayed(speakFor);
  await audio.stop();
  final pcm = chunks.takeBytes();
  final seconds = pcm.length / 2 / AudioCaptureService.sampleRate;
  log('Captured ${pcm.length} bytes (${seconds.toStringAsFixed(2)}s)');
  if (stoppedReason != null) {
    return fail('Capture stopped early (reason=$stoppedReason).');
  }
  if (seconds < 1) {
    return fail('Too little audio arrived to identify a language.');
  }

  // 3. Detector only.
  LanguageDetection detection;
  final started = DateTime.now();
  try {
    detection = await AudioLanguageId.detect(pcm);
  } on PlatformException catch (error) {
    return fail('Detection failed — ${error.message}');
  }
  final ms = DateTime.now().difference(started).inMilliseconds;
  final name = languageForCode(detection.language)?.name ?? detection.language;
  log('Detection time: ${ms}ms');
  log('Language: $name (${detection.language})');
  log('Confidence: ${(detection.confidence * 100).toStringAsFixed(1)}%');
  log('[LANG-ID]');
  var rank = 1;
  for (final (code, prob) in detection.alternatives) {
    final altName = languageForCode(code)?.name ?? code;
    log('$rank. $altName ${prob.toStringAsFixed(2)}');
    rank++;
  }
  log('Apple speech path for $name: ${detection.speechPath}');
  log('Language detection: PASS');
  return LanguageIdTestReport(passed: true, details: lines.join('\n'));
}
