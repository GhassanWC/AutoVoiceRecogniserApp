import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_capture_service.dart';
import 'mic_permission_service.dart';

/// Result of Settings → Developer → Test Microphone Permission.
class MicDiagnosticsReport {
  const MicDiagnosticsReport({required this.passed, required this.details});
  final bool passed;

  /// Full multi-line diagnostic text (also emitted to the developer log).
  final String details;
}

/// Proves the microphone path WITHOUT Whisper: reads the native iOS
/// permission state directly, prints the [MIC PERMISSION] block, then
/// captures 2 seconds of PCM through the same native pipeline Start
/// Listening uses and reports "Audio capture: PASS".
///
/// Requests the permission only when the native state is genuinely
/// undetermined — and only through MicPermissionService's single iOS path.
Future<MicDiagnosticsReport> runMicPermissionTest({
  MicPermissionService? permissions,
  AudioCaptureService? capture,
  Duration captureFor = const Duration(seconds: 2),
}) async {
  const control = MethodChannel('app.livetranslator/audio');
  final service = permissions ?? MicPermissionService();
  final lines = <String>[];
  void log(String line) {
    lines.add(line);
    developer.log(line, name: 'mic');
  }

  MicDiagnosticsReport fail(String reason) {
    log('Audio capture: FAIL — $reason');
    return MicDiagnosticsReport(passed: false, details: lines.join('\n'));
  }

  // What the Flutter-side plugin helper THINKS (status only — never request
  // through it): shown purely so a native/plugin disagreement is visible.
  String flutterStatus;
  try {
    flutterStatus = kIsWeb ? 'unsupported' : (await Permission.microphone.status).name;
  } catch (_) {
    flutterStatus = 'unavailable';
  }

  // The native truth, read directly from AVAudioSession.
  Map<Object?, Object?> native = const {};
  try {
    native = await control.invokeMethod<Map<Object?, Object?>>('micDiagnostics') ?? const {};
  } catch (_) {
    // Android/web/tests: no native diagnostics method on this platform.
  }
  final nativePermission = '${native['nativeRecordPermission'] ?? 'unavailable'}';

  log('[MIC PERMISSION]');
  log('flutterPermissionStatus=$flutterStatus');
  log('nativeRecordPermission=$nativePermission');
  log('NSMicrophoneUsageDescription present=${native['usageDescriptionPresent'] ?? 'unknown'}');
  log('audioSessionCategory=${native['audioSessionCategory'] ?? 'unknown'}');
  log('audioSessionMode=${native['audioSessionMode'] ?? 'unknown'}');
  log('audioSessionActive=${native['audioSessionActive'] ?? 'unknown'}');
  log('inputAvailable=${native['inputAvailable'] ?? 'unknown'}');
  if (nativePermission == 'granted' && flutterStatus != 'granted') {
    log('note=plugin helper disagrees with iOS — NATIVE WINS; the plugin '
        'answer is ignored everywhere in this app');
  }

  var permission = nativePermission;
  if (permission == 'undetermined') {
    // Genuinely never asked: run the one legitimate OS request.
    log('requesting permission (native state undetermined)…');
    final requested = await service.request();
    permission =
        requested == MicPermissionStatus.granted ? 'granted' : 'denied';
    log('afterRequest=$permission');
  } else if (permission == 'unavailable') {
    // No native channel (not iOS) — trust the cross-platform service.
    final status = await service.currentStatus();
    permission = status == MicPermissionStatus.granted ? 'granted' : 'denied';
  }

  if (permission != 'granted') {
    log('Native microphone permission: DENIED');
    return fail('iOS reports the microphone permission is not granted. '
        'Enable it in Settings → Live Translator → Microphone.');
  }
  log('Native microphone permission: GRANTED');

  // 2 seconds of PCM through the exact native path Start Listening uses.
  if (native['audioSessionActive'] == true) {
    return fail('capture is already running — stop Listening first, '
        'then run this test again.');
  }
  final audio = capture ?? AudioCaptureService();
  var bytes = 0;
  var peak = 0;
  var sumSquares = 0.0;
  var samples = 0;
  String? stoppedReason;
  try {
    await audio.start(
      onAudio: (Uint8List pcm) {
        bytes += pcm.length;
        final data = ByteData.sublistView(pcm);
        for (var i = 0; i + 1 < pcm.length; i += 2) {
          final s = data.getInt16(i, Endian.little);
          if (s.abs() > peak) peak = s.abs();
          sumSquares += (s / 32768.0) * (s / 32768.0);
          samples++;
        }
      },
      onStopped: (reason) => stoppedReason = reason,
    );
  } on AudioCaptureUnsupportedException {
    return fail('native audio capture is unavailable on this platform.');
  } catch (error) {
    return fail('native capture failed to start: $error');
  }
  await Future<void>.delayed(captureFor);
  await audio.stop();

  final seconds = samples / AudioCaptureService.sampleRate;
  final rms = samples == 0 ? 0.0 : math.sqrt(sumSquares / samples);
  log('[MIC CAPTURE]');
  log('bytes=$bytes');
  log('samples=$samples (${seconds.toStringAsFixed(2)}s @ ${AudioCaptureService.sampleRate} Hz)');
  log('peak=$peak/32767');
  log('rms=${rms.toStringAsFixed(5)}');
  if (stoppedReason != null) {
    return fail('capture stopped early (reason=$stoppedReason).');
  }
  // At least half the requested audio must have arrived…
  final minSamples =
      AudioCaptureService.sampleRate * captureFor.inMilliseconds ~/ 2000;
  if (samples < minSamples) {
    return fail('only ${seconds.toStringAsFixed(2)}s of audio arrived — '
        'the native pipeline is not delivering PCM.');
  }
  // …and it must not be digital silence: iOS delivers all-zero buffers when
  // capture is blocked at the OS level despite the session starting.
  if (peak == 0) {
    return fail('audio arrived but every sample is zero — iOS is delivering '
        'silence (another app may hold the microphone, or capture is blocked).');
  }
  log('Audio capture: PASS');
  return MicDiagnosticsReport(passed: true, details: lines.join('\n'));
}
