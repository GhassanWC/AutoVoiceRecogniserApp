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

  test('geminiCodeFor maps the catalog to Gemini BCP-47 forms', () {
    expect(geminiCodeFor('zh'), 'zh-Hans');
    expect(geminiCodeFor('pt'), 'pt-BR');
    expect(geminiCodeFor('ar'), 'ar');
    expect(geminiCodeFor('EN'), 'en');
  });

  test('catalog ↔ Cloud Function allowlist parity fixture', () {
    // Mirror of functions/src/languages.ts ALLOWED_TARGET_LANGUAGES — the
    // functions test pins the other direction. Update BOTH together.
    const allowlist = {
      'ar', 'en', 'es', 'fr', 'de', 'hi', 'zh-Hans', 'ja', 'ko', 'tr',
      'pt-BR', 'ru', 'th', 'id', 'ms', 'it', 'nl', 'ur', 'fa', 'he',
      'vi', 'pl', 'uk', 'el', 'sv',
    };
    expect(
      kTargetLanguages.map((l) => geminiCodeFor(l.code)).toSet(),
      allowlist,
    );
  });

  test('normalizeDetectedLanguage folds Gemini BCP-47 codes back to the catalog', () {
    expect(normalizeDetectedLanguage('pt-BR'), 'pt');
    expect(normalizeDetectedLanguage('zh-Hans'), 'zh');
    expect(normalizeDetectedLanguage('en-US'), 'en');
    expect(normalizeDetectedLanguage('ar'), 'ar');
    expect(normalizeDetectedLanguage('xx-YY'), 'xx');
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
