import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/models/app_settings.dart';
import 'package:live_translator/models/translation_message.dart';

void main() {
  test('AppSettings JSON round-trip preserves everything', () {
    const settings = AppSettings(
      targetLanguage: 'ar',
      showOriginalText: false,
      showTimestamps: false,
      showLanguageLabels: false,
      autoSpeak: false,
      themeMode: ThemeMode.dark,
      textSize: AppTextSize.large,
      onboardingComplete: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.toJson(), settings.toJson());
  });

  test('settings persisted by the pre-Gemini app still parse (removed fields ignored)', () {
    final legacy = AppSettings.fromJson(const {
      'targetLanguage': 'ar',
      'saveHistory': true,
      'serverUrl': 'http://192.168.1.5:8080',
      'mockMode': true,
      'translationEngine': 'onDevice',
      'onDeviceModel': 'large-v3-turbo-q5_0',
      'listenLanguages': ['en', 'th'],
    });
    expect(legacy.targetLanguage, 'ar');
    expect(legacy.onboardingComplete, isFalse);
    expect(legacy.autoSpeak, isTrue); // new default: play translated speech
  });

  test('TranslationMessage JSON round-trip', () {
    final message = TranslationMessage(
      id: 'm1',
      speakerId: null,
      speakerLabel: null,
      sourceLanguage: 'es',
      languageConfidence: 1,
      originalText: 'Hola hermano.',
      translatedText: 'مرحباً يا أخي',
      targetLanguage: 'ar',
      timestamp: DateTime.utc(2026, 8, 27, 12, 1),
    );
    final restored = TranslationMessage.fromJson(message.toJson());
    expect(restored.id, 'm1');
    expect(restored.translatedText, 'مرحباً يا أخي');
    expect(restored.sourceLanguage, 'es');
  });
}
