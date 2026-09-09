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

    test('supported-but-not-installed models are pending downloads, NOT unsupported', () {
      final support = LiveTranslationSupport.fromMap({
        'supported': true,
        'updateRequired': false,
        'reason': 'Supported. Language packs to download: ar, bn, hi, th.',
        'osVersion': 'iOS 26.0',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': true,
        'availableLanguages': ['ar', 'bn', 'en', 'hi', 'th'],
        'readyLanguages': ['en'],
        'pendingDownloads': ['ar', 'bn', 'hi', 'th'],
        'missingLanguages': <String>[],
        'languageStatus': {
          'en': 'ready',
          'ar': 'downloadRequired',
          'hi': 'downloadRequired',
          'th': 'downloadRequired',
          'bn': 'downloadRequired',
        },
        'speechDiagnostics': [
          'supportedLocales=ar-SA bn-IN en-US hi-IN th-TH',
          'installedLocales=en-US',
        ],
      });
      // The iPhone 16 Pro Max case: only English installed, but Apple
      // SUPPORTS the rest → the device is supported with downloads pending.
      expect(support.supported, isTrue);
      expect(support.readyLanguages, ['en']);
      expect(support.pendingDownloads, ['ar', 'bn', 'hi', 'th']);
      expect(support.languageStatus['ar'], 'downloadRequired');
      expect(support.partiallySupported, isFalse);
      expect(support.speechDiagnostics.first, contains('supportedLocales='));
    });

    test('ONE installed language is fully valid — never "unsupported"', () {
      // Test A/H shape: fresh iPhone, only English installed and selected.
      final support = LiveTranslationSupport.fromMap({
        'supported': true,
        'updateRequired': false,
        'reason': 'Supported',
        'osVersion': 'iOS 26.0',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': true,
        'supportedLanguages': ['ar', 'en', 'es', 'hi', 'th'],
        'installedLanguages': ['en'],
        'reservedLocales': <String>[],
        'maximumReservedLocales': 5,
        'availableLanguages': ['en'],
        'readyLanguages': ['en'],
        'pendingDownloads': <String>[],
        'missingLanguages': <String>[],
        'languageStatus': {'en': 'ready'},
      });
      expect(support.supported, isTrue,
          reason: 'one installed+selected language must be startable');
      expect(support.maximumReservedLocales, 5);
      // statusFor derives from the raw inventories for ANY picker language:
      expect(support.statusFor('en'), 'ready');
      expect(support.statusFor('th'), 'downloadRequired');
      expect(support.statusFor('xx'), 'unsupported');
    });

    test('selected pending downloads never flip the device to unsupported', () {
      // Test B/H shape: English installed, Thai selected but not installed.
      final support = LiveTranslationSupport.fromMap({
        'supported': true,
        'updateRequired': false,
        'reason': 'Supported. Language packs to download: th.',
        'osVersion': 'iOS 26.0',
        'speechSupported': true,
        'languageDetectionSupported': true,
        'translationSupported': true,
        'supportedLanguages': ['en', 'th'],
        'installedLanguages': ['en'],
        'readyLanguages': ['en'],
        'pendingDownloads': ['th'],
        'languageStatus': {'en': 'ready', 'th': 'downloadRequired'},
      });
      expect(support.supported, isTrue);
      expect(support.pendingDownloads, ['th']);
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
