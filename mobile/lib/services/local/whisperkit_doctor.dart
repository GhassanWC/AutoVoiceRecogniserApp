import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../audio/audio_capture_service.dart';
import '../permissions/mic_permission_service.dart';
import 'local_speech_engine.dart';
import 'whisperkit_models.dart';

class WhisperKitTestReport {
  const WhisperKitTestReport({required this.passed, required this.details});
  final bool passed;

  /// Full multi-line diagnostic text (also emitted to the developer log).
  final String details;
}

/// Settings → Developer → Test WhisperKit.
///
/// End-to-end proof of the Phase A chain on THIS device, with the real
/// engine and the real microphone: initialize WhisperKit, load/download the
/// selected Core ML model (timed), capture a short spoken phrase through the
/// same native pipeline Start Listening uses, transcribe it, and report the
/// transcript plus the detected language code.
Future<WhisperKitTestReport> runWhisperKitTest({
  required String modelKey,
  LocalSpeechEngine? engine,
  MicPermissionService? permissions,
  AudioCaptureService? capture,
  Duration speakFor = const Duration(seconds: 4),
}) async {
  final spec = whisperKitModelForKey(modelKey);
  final lines = <String>[];
  void log(String line) {
    lines.add(line);
    developer.log(line, name: 'whisperkit');
  }

  WhisperKitTestReport fail(String reason) {
    log(reason);
    return WhisperKitTestReport(passed: false, details: lines.join('\n'));
  }

  log('[WHISPERKIT TEST]');
  log('model=${spec.displayName}');
  log('variant=${spec.variant}');

  // 1. Init + model load (downloads on first use — keep the app open).
  final testEngine = engine ?? WhisperKitSpeechEngine();
  final loadStarted = DateTime.now();
  try {
    await testEngine.load(spec.variant);
  } on PlatformException catch (error) {
    log('WhisperKit init: FAIL');
    return fail('Model load: FAIL — ${error.code}: ${error.message}');
  } catch (error) {
    log('WhisperKit init: FAIL');
    return fail('Model load: FAIL — $error');
  }
  final loadMs = DateTime.now().difference(loadStarted).inMilliseconds;
  log('WhisperKit init: PASS');
  log('Model load: PASS (${loadMs}ms${loadMs > 60000 ? ', includes first-time download' : ''})');

  // 2. Microphone permission (native truth; request only if undetermined).
  final service = permissions ?? MicPermissionService();
  var permission = await service.currentStatus();
  if (permission == MicPermissionStatus.denied) {
    permission = await service.request();
  }
  if (permission != MicPermissionStatus.granted) {
    return fail('Capture: FAIL — microphone permission is not granted '
        '(enable it in Settings → Live Translator → Microphone).');
  }

  // 3. Capture a short phrase through the exact pipeline Start Listening uses.
  log('Speak now (${speakFor.inSeconds}s)…');
  final audio = capture ?? AudioCaptureService();
  final chunks = BytesBuilder(copy: true);
  String? stoppedReason;
  try {
    await audio.start(
      onAudio: chunks.add,
      onStopped: (reason) => stoppedReason = reason,
    );
  } on AudioCaptureUnsupportedException {
    return fail('Capture: FAIL — native audio capture is unavailable here.');
  } catch (error) {
    return fail('Capture: FAIL — could not start the microphone: $error');
  }
  await Future<void>.delayed(speakFor);
  await audio.stop();
  final pcm = chunks.takeBytes();
  final seconds = pcm.length / 2 / AudioCaptureService.sampleRate;
  log('Captured ${pcm.length} bytes (${seconds.toStringAsFixed(2)}s)');
  if (stoppedReason != null) {
    return fail('Capture: FAIL — stopped early (reason=$stoppedReason).');
  }
  if (seconds < speakFor.inSeconds / 2) {
    return fail('Capture: FAIL — the native pipeline is not delivering PCM.');
  }

  // 4. Transcribe + language detection.
  try {
    final started = DateTime.now();
    final transcript =
        await testEngine.transcribe(pcm, AudioCaptureService.sampleRate);
    final ms = DateTime.now().difference(started).inMilliseconds;
    log('Transcribe time: ${ms}ms for ${seconds.toStringAsFixed(1)}s audio');
    log('Transcript: ${transcript.text.isEmpty ? '(empty — was anything said?)' : transcript.text}');
    log('Language: ${transcript.language}');
    if (transcript.text.isEmpty) {
      return fail('Transcription ran but heard nothing — say a short phrase '
          'while the test is capturing and run it again.');
    }
  } on PlatformException catch (error) {
    return fail('Transcribe: FAIL — ${error.code}: ${error.message}');
  } catch (error) {
    return fail('Transcribe: FAIL — $error');
  } finally {
    // The test's engine instance is disposable; a real session loads its own.
    if (engine == null) await testEngine.dispose().catchError((_) {});
  }
  log('WhisperKit end-to-end: PASS');
  return WhisperKitTestReport(passed: true, details: lines.join('\n'));
}
