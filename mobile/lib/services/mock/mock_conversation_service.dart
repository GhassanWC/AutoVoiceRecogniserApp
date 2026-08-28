import 'dart:async';

import '../../models/translation_message.dart';

class _MockLine {
  const _MockLine(this.speakerNumber, this.language, this.original, this.translations);
  final int speakerNumber;
  final String language;
  final String original;

  /// targetLanguage → translation.
  final Map<String, String> translations;
}

const List<_MockLine> _script = [
  _MockLine(1, 'es', 'Hola hermano, ¿cómo estás?', {
    'ar': 'مرحباً يا أخي، كيف حالك؟',
    'en': 'Hello brother, how are you?',
  }),
  _MockLine(2, 'en', 'My mother is sick.', {
    'ar': 'أمي مريضة.',
    'en': 'My mother is sick.',
  }),
  _MockLine(3, 'fr', "Où est l'hôtel?", {
    'ar': 'أين الفندق؟',
    'en': 'Where is the hotel?',
  }),
  _MockLine(1, 'es', '¿Quieres venir con nosotros?', {
    'ar': 'هل تريد الذهاب معنا؟',
    'en': 'Do you want to come with us?',
  }),
  _MockLine(2, 'en', 'The restaurant closes at nine.', {
    'ar': 'المطعم يغلق الساعة التاسعة.',
    'en': 'The restaurant closes at nine.',
  }),
  _MockLine(3, 'fr', 'Nous arriverons dans dix minutes.', {
    'ar': 'سنصل بعد عشر دقائق.',
    'en': 'We will arrive in ten minutes.',
  }),
  _MockLine(1, 'es', 'No te preocupes, todo saldrá bien.', {
    'ar': 'لا تقلق، كل شيء سيكون على ما يرام.',
    'en': "Don't worry, everything will be fine.",
  }),
];

/// Demo Mode: generates the product's example conversation on a timer so the
/// full UI can be exercised with no microphone, no backend and no paid APIs.
class MockConversationService {
  Timer? _timer;
  int _index = 0;
  int _counter = 0;

  bool get isRunning => _timer != null;

  void start({
    required String targetLanguage,
    required void Function(String state) onStatus,
    required void Function(TranslationMessage message) onMessage,
  }) {
    stop();
    _timer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
      final line = _script[_index % _script.length];
      _index++;
      onStatus('hearing');
      Timer(const Duration(milliseconds: 900), () {
        if (!isRunning) return;
        onStatus('translating');
      });
      Timer(const Duration(milliseconds: 1600), () {
        if (!isRunning) return;
        _counter++;
        onMessage(
          TranslationMessage(
            id: 'mock_$_counter',
            speakerId: 'speaker_${line.speakerNumber}',
            speakerLabel: 'Speaker ${line.speakerNumber}',
            sourceLanguage: line.language,
            languageConfidence: 0.95,
            originalText: line.original,
            translatedText:
                line.translations[targetLanguage] ?? '[$targetLanguage] ${line.original}',
            targetLanguage: targetLanguage,
            timestamp: DateTime.now(),
          ),
        );
      });
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _index = 0;
  }
}
