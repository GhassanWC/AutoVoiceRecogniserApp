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
/// This diagnostic answers exactly one question: can WhisperKit load and
/// transcribe using the model ALREADY STORED INSIDE THE APP? Zero network:
/// 1. Bundled model found: YES/NO (checks Bundle.main, listing any missing piece)
/// 2. Model load: PASS (download:false, hard 30 s native timeout)
/// 3. Speak now… (capture through the same native pipeline Start Listening uses)
/// 4. Transcript + Language from the spoken phrase.
Future<WhisperKitTestReport> runWhisperKitTest({
  required String modelKey,
  LocalSpeechEngine? engine,
  MicPermissionService? permissions,
  AudioCaptureService? capture,
  Duration speakFor = const Duration(seconds: 4),
}) async {
  const channel = MethodChannel('app.livetranslator/whisperkit');
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

  log('[WHISPERKIT TEST — bundled model, zero network]');
  log('variant=${spec.variant}');

  // 1. Is the CI-bundled model actually inside this build?
  try {
    final info = await channel.invokeMethod<Map<Object?, Object?>>(
      'bundledModel',
      {'variant': spec.variant},
    );
    final found = info?['found'] == true;
    log('Bundled model found: ${found ? 'YES' : 'NO'}');
    if (!found) {
      final pieces = (info?['pieces'] as Map<Object?, Object?>? ?? {});
      for (final entry in pieces.entries) {
        log('  ${entry.value == true ? 'ok     ' : 'MISSING'} ${entry.key}');
      }
      return fail('This build was made without the CI model-bundling step — '
          'nothing is downloaded at runtime, so WhisperKit cannot load.');
    }
  } on MissingPluginException {
    return fail('Bundled model found: NO — this platform has no WhisperKit '
        'bridge (iOS only).');
  }

  // 2. Model load, strictly from the bundle (native 30 s hard timeout).
  final testEngine = engine ?? WhisperKitSpeechEngine();
  final loadStarted = DateTime.now();
  try {
    await testEngine.load(spec.variant);
  } on PlatformException catch (error) {
    return fail('Model load: FAIL — ${error.code}: ${error.message}');
  } catch (error) {
    return fail('Model load: FAIL — $error');
  }
  log('Model load: PASS (${DateTime.now().difference(loadStarted).inMilliseconds}ms)');

  // 3. Microphone permission (native truth; request only if undetermined).
  final service = permissions ?? MicPermissionService();
  var permission = await service.currentStatus();
  if (permission == MicPermissionStatus.denied) {
    permission = await service.request();
  }
  if (permission != MicPermissionStatus.granted) {
    return fail('Capture: FAIL — microphone permission is not granted '
        '(enable it in Settings → Live Translator → Microphone).');
  }

  // 4. Capture a short phrase through the exact pipeline Start Listening uses.
  log('Speak now… (${speakFor.inSeconds}s)');
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

  // 5. Transcribe + language detection.
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
