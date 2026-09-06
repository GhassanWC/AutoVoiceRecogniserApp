import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/features/live_translation/widgets/message_bubble.dart';
import 'package:live_translator/models/translation_message.dart';

TranslationMessage _arabicMessage() => TranslationMessage(
      id: 'm1',
      speakerId: 'speaker_2',
      speakerLabel: 'Speaker 2',
      sourceLanguage: 'en',
      languageConfidence: 0.94,
      originalText: 'Where is the bus station?',
      translatedText: 'أين محطة الحافلات؟',
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 8, 27, 14, 32),
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('shows translation, original, speaker and language', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _arabicMessage(),
      showOriginal: true,
      showTimestamp: true,
      showLanguageLabels: true,
    )));

    expect(find.textContaining('أين محطة الحافلات؟'), findsOneWidget);
    expect(find.textContaining('Where is the bus station?'), findsOneWidget);
    expect(find.textContaining('Speaker 2'), findsOneWidget);
    expect(find.textContaining('English'), findsOneWidget);
    expect(find.textContaining('14:32'), findsOneWidget);
  });

  testWidgets('renders the Arabic translation right-to-left', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _arabicMessage(),
      showOriginal: true,
      showTimestamp: false,
      showLanguageLabels: true,
    )));

    final translated = tester.widget<Text>(find.text('أين محطة الحافلات؟'));
    expect(translated.textDirection, TextDirection.rtl);
    final original = tester.widget<Text>(find.text('Where is the bus station?'));
    expect(original.textDirection, TextDirection.ltr);
  });

  testWidgets('respects the hide-original and hide-labels settings', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(
      message: _arabicMessage(),
      showOriginal: false,
      showTimestamp: false,
      showLanguageLabels: false,
    )));

    expect(find.textContaining('Where is the bus station?'), findsNothing);
    expect(find.textContaining('English'), findsNothing);
    expect(find.textContaining('أين محطة الحافلات؟'), findsOneWidget);
  });

  testWidgets('shows the transcript with "Translating…" while translation is pending',
      (tester) async {
    final pending = TranslationMessage(
      id: 'm3',
      speakerId: 'speaker_1',
      speakerLabel: 'Speaker 1',
      sourceLanguage: 'en',
      languageConfidence: 0.9,
      originalText: 'Where is the hotel?',
      translatedText: '',
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 9, 5, 10, 0),
      status: TranslationStatus.pending,
    );
    await tester.pumpWidget(_wrap(MessageBubble(
      message: pending,
      showOriginal: true,
      showTimestamp: false,
      showLanguageLabels: true,
    )));

    expect(find.text('Translating…'), findsOneWidget);
    expect(find.textContaining('Where is the hotel?'), findsOneWidget); // transcript stays
    expect(find.text('Translation failed'), findsNothing);
    // Let the progress indicator's animation settle before teardown.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('renders streamed partial translation text while still pending', (tester) async {
    final streamingMessage = TranslationMessage(
      id: 'm5',
      speakerId: 'speaker_1',
      speakerLabel: 'Speaker 1',
      sourceLanguage: 'en',
      languageConfidence: 0.9,
      originalText: 'Where is the hotel?',
      translatedText: 'أين', // first delta already arrived
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 9, 5, 10, 0),
      status: TranslationStatus.pending,
    );
    await tester.pumpWidget(_wrap(MessageBubble(
      message: streamingMessage,
      showOriginal: true,
      showTimestamp: false,
      showLanguageLabels: true,
    )));

    // Live subtitles: the partial text shows instead of a spinner.
    expect(find.text('أين'), findsOneWidget);
    expect(find.text('Translating…'), findsNothing);
  });

  testWidgets('shows "Translation failed" with a Retry action and keeps the transcript',
      (tester) async {
    var retried = false;
    final failed = TranslationMessage(
      id: 'm4',
      speakerId: 'speaker_1',
      speakerLabel: 'Speaker 1',
      sourceLanguage: 'en',
      languageConfidence: 0.9,
      originalText: 'Where is the hotel?',
      translatedText: '',
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 9, 5, 10, 0),
      status: TranslationStatus.failed,
    );
    await tester.pumpWidget(_wrap(MessageBubble(
      message: failed,
      showOriginal: true,
      showTimestamp: false,
      showLanguageLabels: true,
      onRetry: () => retried = true,
    )));

    expect(find.text('Translation failed'), findsOneWidget);
    expect(find.textContaining('Where is the hotel?'), findsOneWidget); // transcript preserved
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('falls back to the generic speaker label', (tester) async {
    final message = TranslationMessage(
      id: 'm2',
      speakerId: null,
      speakerLabel: null,
      sourceLanguage: 'und',
      languageConfidence: 0,
      originalText: 'something unclear',
      translatedText: 'شيء غير واضح',
      targetLanguage: 'ar',
      timestamp: DateTime(2026, 8, 27, 9, 0),
    );
    await tester.pumpWidget(_wrap(MessageBubble(
      message: message,
      showOriginal: false,
      showTimestamp: false,
      showLanguageLabels: true,
    )));

    // Unknown language → just "Speaker", never a "Language detected…" text.
    expect(find.textContaining('Speaker'), findsOneWidget);
    expect(find.textContaining('Language detected'), findsNothing);
    expect(find.text('Speaker'), findsOneWidget); // no trailing separator
  });
}
