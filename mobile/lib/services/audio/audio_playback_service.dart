import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge to native streamed PCM playback (Gemini's translated speech).
///
/// Uses the same control channel as capture (`app.livetranslator/audio`) with
/// `playbackStart` / `playbackChunk` / `playbackStop`, plus a dedicated event
/// channel that reports when the native queue is audibly draining. That
/// signal is ground truth for the half-duplex gate: while the device is
/// speaking a translation, microphone chunks are NOT sent to Gemini, so the
/// speaker output can't loop back in as new speech.
class AudioPlaybackService {
  static const MethodChannel _control = MethodChannel('app.livetranslator/audio');
  static const EventChannel _events = EventChannel('app.livetranslator/playback_events');

  /// Gemini Live Translate output format.
  static const int sampleRate = 24000;

  final StreamController<bool> _active = StreamController<bool>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _isActive = false;

  /// True while translated audio is audibly playing.
  bool get isActive => _isActive;

  /// Emits true when playback starts draining, false when the queue runs dry.
  Stream<bool> get playbackActive => _active.stream;

  Future<void> start() async {
    _subscription ??= _events.receiveBroadcastStream().listen((dynamic event) {
      if (event is Map) {
        final active = event['active'] == true;
        if (active != _isActive) {
          _isActive = active;
          _active.add(active);
        }
      }
    }, onError: (Object _) {});
    try {
      await _control.invokeMethod<void>('playbackStart', {'sampleRate': sampleRate});
    } on MissingPluginException {
      // Platform without native playback (web/desktop preview) — text-only.
    }
  }

  Future<void> feed(Uint8List pcm) async {
    if (pcm.isEmpty) return;
    try {
      await _control.invokeMethod<void>('playbackChunk', {'data': pcm});
    } on MissingPluginException {
      // ignore: text-only platforms
    }
  }

  /// Stops playback immediately and flushes anything queued (used both for
  /// clean shutdown and when Gemini reports the model turn was interrupted).
  Future<void> stop() async {
    try {
      await _control.invokeMethod<void>('playbackStop');
    } on MissingPluginException {
      // ignore
    }
    if (_isActive) {
      _isActive = false;
      _active.add(false);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _subscription?.cancel();
    _subscription = null;
    await _active.close();
  }
}
