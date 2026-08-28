import 'package:flutter_tts/flutter_tts.dart';

/// Speaks translations aloud (Earphone Mode / "Speak translations").
/// Utterances queue so overlapping messages do not talk over each other.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  String? _language;

  Future<void> _ensureInitialized(String languageCode) async {
    if (!_initialized) {
      try {
        await _tts.awaitSpeakCompletion(false);
        // Queue instead of interrupting the current utterance (Android).
        await _tts.setQueueMode(1);
      } catch (_) {
        // TTS unavailable on this platform — speak() becomes a no-op.
      }
      _initialized = true;
    }
    if (_language != languageCode) {
      try {
        await _tts.setLanguage(languageCode);
        _language = languageCode;
      } catch (_) {
        // Unsupported voice — keep the previous language rather than failing.
      }
    }
  }

  Future<void> speak(String text, String languageCode) async {
    if (text.trim().isEmpty) return;
    await _ensureInitialized(languageCode);
    try {
      await _tts.speak(text);
    } catch (_) {
      // Never let TTS problems interfere with translation display.
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
