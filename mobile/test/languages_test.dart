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

  test('softens the label when detection confidence is low', () {
    expect(detectedLanguageLabel('es', 0.95), 'Spanish');
    expect(detectedLanguageLabel('es', 0.3), 'Language detected automatically');
    expect(detectedLanguageLabel('und', 0.99), 'Language detected automatically');
    expect(detectedLanguageLabel(null, 1.0), 'Language detected automatically');
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
