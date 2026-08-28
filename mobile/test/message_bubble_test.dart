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

    expect(find.textContaining('Speaker'), findsOneWidget);
    expect(find.textContaining('Language detected automatically'), findsOneWidget);
  });
}
