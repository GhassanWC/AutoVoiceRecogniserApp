import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge to the native microphone capture implementation.
///
/// Both platforms are configured for *environmental* listening (the whole
/// room, including distant speakers and TV audio) — never for near-field
/// voice-call capture:
///  - Android: AudioRecord @16 kHz mono PCM16 with only AutomaticGainControl
///    attached (no noise suppression / echo cancellation, which strip distant
///    speech), wrapped in a microphone foreground service with a persistent
///    "Listening" notification that carries a Stop action.
///  - iOS: AVAudioEngine in `.measurement` mode with voice-processing I/O
///    disabled and an omnidirectional mic preference, `audio` background
///    mode, resampled to 16 kHz mono PCM16.
///
/// Events from the EventChannel are either a Uint8List (an audio chunk) or a
/// map like {'event': 'stopped', 'reason': 'notification'} when capture ended
/// outside the app UI (notification Stop button, mic taken by a call, OS kill).
class AudioCaptureService {
  static const MethodChannel _control = MethodChannel('app.livetranslator/audio');
  static const EventChannel _events = EventChannel('app.livetranslator/audio_events');

  static const int sampleRate = 16000;

  StreamSubscription<dynamic>? _subscription;

  /// True between a successful [start] and [stop].
  bool get isCapturing => _subscription != null;

  /// Starts native capture. [onAudio] receives PCM16LE mono chunks;
  /// [onStopped] fires if capture ends for any reason other than [stop].
  Future<void> start({
    required void Function(Uint8List pcm) onAudio,
    required void Function(String reason) onStopped,
  }) async {
    if (_subscription != null) return;
    try {
      _subscription = _events.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Uint8List) {
            onAudio(event);
          } else if (event is Map) {
            final reason = event['reason']?.toString() ?? 'unknown';
            _subscription?.cancel();
            _subscription = null;
            onStopped(reason);
          }
        },
        onError: (Object error) {
          _subscription?.cancel();
          _subscription = null;
          onStopped('error');
        },
      );
      await _control.invokeMethod<void>('start', {'sampleRate': sampleRate});
    } on MissingPluginException {
      await _subscription?.cancel();
      _subscription = null;
      throw const AudioCaptureUnsupportedException();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  /// Stops native capture immediately (also removes the Android notification).
  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    try {
      await _control.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Platform without native capture (e.g. web preview) — nothing to stop.
    }
  }
}

/// Thrown on platforms without native capture (web/desktop preview builds);
/// the UI offers Demo Mode instead of failing silently.
class AudioCaptureUnsupportedException implements Exception {
  const AudioCaptureUnsupportedException();
}
