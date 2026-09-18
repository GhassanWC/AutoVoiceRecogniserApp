import 'dart:async';

import 'package:flutter/services.dart';

/// Speaks a translation out loud using the device's own voices —
/// AVSpeechSynthesizer on iOS, android.speech.tts.TextToSpeech on Android.
///
/// This replaced replaying Gemini's generated audio. Gemini's audio arrives
/// mid-session and used to be routed through the speaker, which fed straight
/// back into the live microphone; the device's synthesizer is instead invoked
/// only on an explicit tap, works the instant the translated TEXT is final,
/// and works for history too (nothing has to be kept in memory).
class SpeechService {
  SpeechService({MethodChannel? control, EventChannel? events})
      : _control = control ?? const MethodChannel('app.livetranslator/tts'),
        _events = events ?? const EventChannel('app.livetranslator/tts_events');

  final MethodChannel _control;
  final EventChannel _events;

  StreamSubscription<dynamic>? _subscription;
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();
  bool _isSpeaking = false;

  /// True between a speak() that started and its completion/stop.
  bool get isSpeaking => _isSpeaking;

  /// Emits true when the synthesizer starts and false when it finishes, is
  /// stopped, or fails. Drives the brief microphone gate around manual speech.
  Stream<bool> get speaking => _speaking.stream;

  void _listen() {
    _subscription ??= _events.receiveBroadcastStream().listen((dynamic event) {
      if (event is! Map) return;
      final speaking = event['speaking'] == true;
      if (speaking == _isSpeaking) return;
      _isSpeaking = speaking;
      _speaking.add(speaking);
    }, onError: (Object _) {
      if (!_isSpeaking) return;
      _isSpeaking = false;
      _speaking.add(false);
    });
  }

  /// Speaks [text] using the voice for [languageCode] (BCP-47, e.g. "ar",
  /// "pt-BR"). Returns false when the platform has no synthesizer (web/desktop
  /// preview) or no voice for that language, so the UI can stay honest instead
  /// of showing a control that does nothing.
  Future<bool> speak(String text, {required String languageCode}) async {
    if (text.trim().isEmpty) return false;
    _listen();
    try {
      final spoken = await _control.invokeMethod<bool>(
        'speak',
        {'text': text, 'languageCode': languageCode},
      );
      return spoken ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Stops any speech immediately (used when the user taps another message,
  /// or the session ends).
  Future<void> stop() async {
    try {
      await _control.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No synthesizer on this platform — nothing to stop.
    } on PlatformException {
      // Best effort.
    }
    if (_isSpeaking) {
      _isSpeaking = false;
      _speaking.add(false);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _speaking.close();
  }
}
