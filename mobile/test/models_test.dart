import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/models/app_settings.dart';
import 'package:live_translator/models/conversation_session.dart';
import 'package:live_translator/models/translation_message.dart';

void main() {
  test('AppSettings JSON round-trip preserves everything', () {
    const settings = AppSettings(
      targetLanguage: 'ar',
      showOriginalText: false,
      showTimestamps: false,
      showLanguageLabels: false,
      autoSpeak: true,
      saveHistory: true,
      themeMode: ThemeMode.dark,
      textSize: AppTextSize.large,
      onboardingComplete: true,
      serverUrl: 'http://192.168.1.5:8080',
      mockMode: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.toJson(), settings.toJson());
  });

  test('privacy defaults: history off, nothing speaks automatically', () {
    const settings = AppSettings();
    expect(settings.saveHistory, isFalse);
    expect(settings.autoSpeak, isFalse);
    expect(settings.mockMode, isFalse);
  });

  test('ConversationSession JSON round-trip preserves messages', () {
    final session = ConversationSession(
      id: 'session_1',
      targetLanguage: 'ar',
      startedAt: DateTime.utc(2026, 8, 27, 12),
      endedAt: DateTime.utc(2026, 8, 27, 12, 5),
      messages: [
        TranslationMessage(
          id: 'm1',
          speakerId: 'speaker_1',
          speakerLabel: 'Speaker 1',
          sourceLanguage: 'es',
          languageConfidence: 0.96,
          originalText: 'Hola hermano.',
          translatedText: 'مرحباً يا أخي',
          targetLanguage: 'ar',
          timestamp: DateTime.utc(2026, 8, 27, 12, 1),
        ),
      ],
    );
    final restored = ConversationSession.fromJson(session.toJson());
    expect(restored.id, 'session_1');
    expect(restored.messages, hasLength(1));
    expect(restored.messages.single.translatedText, 'مرحباً يا أخي');
    expect(restored.messages.single.speakerLabel, 'Speaker 1');
  });
}
