import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/services/native/live_translation_support.dart';

void main() {
  group('LiveTranslationSupport', () {
    test('fromMap parses a full native probe payload', () {
      final support = LiveTranslationSupport.fromMap({
        'supported': true,
        'updateRequired': false,
        'reason': 'Supported',
        'osVersion': 'iOS 18.6',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': true,
        'availableLanguages': ['ar', 'en', 'hi'],
        'missingLanguages': ['bn', 'th'],
        'translationPairs': {'en': 'installed', 'hi': 'downloadable'},
      });
      expect(support.supported, isTrue);
      expect(support.osVersion, 'iOS 18.6');
      expect(support.availableLanguages, ['ar', 'en', 'hi']);
      expect(support.missingLanguages, ['bn', 'th']);
      expect(support.translationPairs['hi'], 'downloadable');
      expect(support.partiallySupported, isFalse);
    });

    test('speech-only devices are PARTIALLY supported, never silently degraded', () {
      final support = LiveTranslationSupport.fromMap({
        'supported': false,
        'updateRequired': false,
        'reason': 'no translation',
        'osVersion': 'iOS 18.0',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': false,
      });
      expect(support.supported, isFalse);
      expect(support.partiallySupported, isTrue,
          reason: 'speech works but translation missing → partial wording');
    });

    test('an old OS is an UPDATE REQUIRED case, not a broken-phone case', () {
      final support = LiveTranslationSupport.fromMap({
        'supported': false,
        'updateRequired': true,
        'reason': 'needs iOS 18',
        'osVersion': 'iOS 17.5',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': false,
      });
      expect(support.updateRequired, isTrue);
      // The update case takes precedence over the partial wording in the UI.
    });

    test('a missing platform channel degrades to honest unsupported, no crash', () {
      final support = LiveTranslationSupport.unsupportedPlatform();
      expect(support.supported, isFalse);
      expect(support.updateRequired, isFalse);
      expect(support.partiallySupported, isFalse);
      expect(support.reason, isNotEmpty);
    });
  });
}
