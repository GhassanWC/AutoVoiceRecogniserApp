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

/// THE single audio-preparation entry point for language identification.
///
/// Every caller — the developer detector tests AND the live session engine —
/// MUST route utterance PCM through this before the native detector, so
/// there is exactly ONE preprocessing pipeline (regression-tested). It
/// normalizes the byte layout on the Dart side; the final 5-second
/// window/padding policy (chosen by CI parity against the official model)
/// is applied natively by SpeechBrainFbank.prepare, identically for all
/// callers.
Uint8List prepareLanguageIdAudio(Uint8List pcm16) {
  var out = pcm16;
  // PCM16 must be an even number of bytes.
  if (out.length.isOdd) {
    out = Uint8List.sublistView(out, 0, out.length - 1);
  }
  // Cap merged utterances at 15 s (center-kept) so a runaway buffer can
  // never balloon the native call; the model window is 5 s anyway.
  const maxSamples = 15 * 16000;
  final totalSamples = out.length ~/ 2;
  if (totalSamples > maxSamples) {
    final startSample = (totalSamples - maxSamples) ~/ 2;
    out = Uint8List.sublistView(
        out, startSample * 2, (startSample + maxSamples) * 2);
  }
  return out;
}

class AudioLanguageId {
  static const MethodChannel _channel = MethodChannel('app.livetranslator/langid');

  /// Whether the model is inside this build + its size + current Apple
  /// speech paths for the core test languages.
  static Future<Map<Object?, Object?>> status() async =>
      await _channel.invokeMethod<Map<Object?, Object?>>('status') ?? {};

  /// Phase 2: utterance → detector → resolver → ONE Apple recognizer for
  /// the detected language → text. Never runs parallel recognizers.
  static Future<DetectTranscribeResult> detectAndTranscribe(
      Uint8List pcm16) async {
    final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
      'detectAndTranscribe',
      {'pcm16': pcm16, 'sampleRate': 16000},
    ).timeout(const Duration(seconds: 90));
    return DetectTranscribeResult(
      language: '${reply?['language'] ?? 'und'}',
      confidence: (reply?['confidence'] as num?)?.toDouble() ?? 0,
      alternatives: [
        for (final alt in reply?['alternatives'] as List<Object?>? ?? [])
          (
            '${(alt as Map<Object?, Object?>)['language']}',
            (alt['confidence'] as num?)?.toDouble() ?? 0,
          )
      ],
      detectionMs: (reply?['detectionMs'] as num?)?.toInt() ?? 0,
      speechAvailable: reply?['speechAvailable'] == true,
      backend: '${reply?['backend'] ?? 'unknown'}',
      locale: reply?['locale'] as String?,
      text: reply?['text'] as String?,
      speechMs: (reply?['speechMs'] as num?)?.toInt(),
      speechError: reply?['speechError'] as String?,
    );
  }

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

/// Result of the Phase-2 chain: detection + single-recognizer transcription.
class DetectTranscribeResult {
  const DetectTranscribeResult({
    required this.language,
    required this.confidence,
    required this.alternatives,
    required this.detectionMs,
    required this.speechAvailable,
    required this.backend,
    required this.locale,
    required this.text,
    required this.speechMs,
    required this.speechError,
  });

  final String language;
  final double confidence;
  final List<(String, double)> alternatives;
  final int detectionMs;

  /// False when Apple has NO recognition path for the detected language —
  /// detection still SUCCEEDED; these are two separate facts.
  final bool speechAvailable;

  /// "transcriber" | "onDevice" | "network" | "unsupported".
  final String backend;
  final String? locale;
  final String? text;
  final int? speechMs;
  final String? speechError;
}

class LanguageIdTestReport {
  const LanguageIdTestReport({required this.passed, required this.details});
  final bool passed;
  final String details;
}

/// Settings → Developer → Test Detect + Transcribe — the Phase-2 proof:
/// one spoken utterance → language detector → AppleSpeechLocaleResolver →
/// exactly ONE Apple recognizer for the detected language → text.
/// No translation. Report shows detected language, confidence, chosen
/// locale + backend, recognized text, and both latencies. Run on a real
/// iPhone in English, Arabic, Hindi, Thai and Bengali.
Future<LanguageIdTestReport> runDetectTranscribeTest({
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

  log('[PHASE 2 TEST — detect → ONE recognizer → text; no translation]');

  Map<Object?, Object?> status;
  try {
    status = await AudioLanguageId.status();
  } on MissingPluginException {
    return fail('Language identification is iOS-only in this build.');
  }
  if (status['modelBundled'] != true) {
    return fail('This build was made without the CI model-conversion step.');
  }

  // Microphone permission (native truth; request only if undetermined).
  final service = permissions ?? MicPermissionService();
  var permission = await service.currentStatus();
  if (permission == MicPermissionStatus.denied) {
    permission = await service.request();
  }
  if (permission != MicPermissionStatus.granted) {
    return fail('Microphone permission is not granted '
        '(enable it in Settings → Live Translator → Microphone).');
  }

  // One utterance through the real environmental pipeline (unchanged).
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
    return fail('Too little audio arrived.');
  }

  DetectTranscribeResult outcome;
  try {
    // Same single preprocessing path the live session uses — never two.
    outcome = await AudioLanguageId.detectAndTranscribe(
        prepareLanguageIdAudio(pcm));
  } on PlatformException catch (error) {
    return fail('Failed — ${error.message}');
  } on TimeoutException {
    return fail('Detect + transcribe did not answer in time.');
  }

  final name = languageForCode(outcome.language)?.name ?? outcome.language;
  log('Detected language: $name (${outcome.language})');
  log('Detection confidence: ${(outcome.confidence * 100).toStringAsFixed(1)}%');
  log('Detection latency: ${outcome.detectionMs}ms');
  var rank = 1;
  for (final (code, prob) in outcome.alternatives) {
    log('  $rank. ${languageForCode(code)?.name ?? code} ${prob.toStringAsFixed(2)}');
    rank++;
  }
  if (!outcome.speechAvailable) {
    // Detection SUCCEEDED; Apple just cannot transcribe this language here.
    log('$name was detected, but speech recognition is not available '
        'for it on this device.');
    return LanguageIdTestReport(passed: false, details: lines.join('\n'));
  }
  log('Chosen Apple locale: ${outcome.locale ?? 'unknown'}');
  log('Speech backend: ${switch (outcome.backend) {
    'transcriber' => 'SpeechTranscriber (installed, on-device)',
    'onDevice' => 'SFSpeechRecognizer (on-device)',
    'network' => 'SFSpeechRecognizer (Apple network)',
    _ => outcome.backend,
  }}');
  if (outcome.speechError != null) {
    log('Speech latency: ${outcome.speechMs ?? '?'}ms');
    return fail('Transcription failed — ${outcome.speechError}');
  }
  log('Speech latency: ${outcome.speechMs ?? '?'}ms');
  final text = outcome.text?.trim() ?? '';
  log('Recognized text: ${text.isEmpty ? '(empty — was anything said?)' : text}');
  if (text.isEmpty) {
    return fail('The recognizer returned no text — speak a clear sentence '
        'and run again.');
  }
  log('Phase 2 (detect → transcribe): PASS');
  return LanguageIdTestReport(passed: true, details: lines.join('\n'));
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
    // Same single preprocessing path the live session uses — never two.
    detection = await AudioLanguageId.detect(prepareLanguageIdAudio(pcm));
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
