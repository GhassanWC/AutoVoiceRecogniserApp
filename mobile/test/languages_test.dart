import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/utils/languages.dart';

void main() {
  test('finds languages by code, case-insensitively', () {
    expect(languageForCode('ar')?.name, 'Arabic');
    expect(languageForCode('AR')?.name, 'Arabic');
    expect(languageForCode('xx'), isNull);
    expect(languageForCode(null), isNull);
  });

  test('knows which languages are RTL', () {
    expect(isRtlLanguage('ar'), isTrue);
    expect(isRtlLanguage('he'), isTrue);
    expect(isRtlLanguage('ur'), isTrue);
    expect(isRtlLanguage('en'), isFalse);
    expect(isRtlLanguage('zh'), isFalse);
  });

  test('unknown/low-confidence detection returns null — bubble shows just "Speaker"', () {
    expect(detectedLanguageLabel('es', 0.95), 'Spanish');
    // Never a "Language detected…" placeholder anymore.
    expect(detectedLanguageLabel('es', 0.3), isNull);
    expect(detectedLanguageLabel('und', 0.99), isNull);
    expect(detectedLanguageLabel(null, 1.0), isNull);
    expect(detectedLanguageFlag('und', 0.99), isNull);
  });

  test('source-language display map covers the product languages with the agreed flags', () {
    // Flags are UI representatives, not nationality claims; ar → 🇴🇲 and
    // en → 🇬🇧 are deliberate product defaults.
    expect(detectedLanguageLabel('th', 0.9), 'Thai');
    expect(detectedLanguageFlag('th', 0.9), '🇹🇭');
    expect(detectedLanguageLabel('bn', 0.9), 'Bengali');
    expect(detectedLanguageFlag('bn', 0.9), '🇧🇩');
    expect(detectedLanguageLabel('hi', 0.9), 'Hindi');
    expect(detectedLanguageFlag('hi', 0.9), '🇮🇳');
    expect(detectedLanguageLabel('ar', 0.9), 'Arabic');
    expect(detectedLanguageFlag('ar', 0.9), '🇴🇲');
    expect(detectedLanguageLabel('en', 0.9), 'English');
    expect(detectedLanguageFlag('en', 0.9), '🇬🇧');
    expect(detectedLanguageLabel('ta', 0.9), 'Tamil');
    expect(detectedLanguageFlag('ta', 0.9), '🇮🇳');
    expect(detectedLanguageLabel('ur', 0.9), 'Urdu');
    expect(detectedLanguageFlag('ur', 0.9), '🇵🇰');
    for (final entry in kSourceLanguageDisplay.entries) {
      expect(entry.value.code, entry.key);
      expect(entry.value.name, isNotEmpty);
      expect(entry.value.flag, isNotEmpty);
    }
  });

  test('every catalog entry is complete', () {
    for (final language in kTargetLanguages) {
      expect(language.code.length, inInclusiveRange(2, 3));
      expect(language.name, isNotEmpty);
      expect(language.nativeName, isNotEmpty);
      expect(language.flag, isNotEmpty);
    }
    // Arabic first — it is the flagship target language.
    expect(kTargetLanguages.first.code, 'ar');
  });
}
