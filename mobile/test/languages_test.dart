import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/utils/languages.dart';

/// Mirror of functions/src/languages.ts ALLOWED_TARGET_LANGUAGES — the
/// functions test pins the other direction. Update BOTH together.
const _allowlist = {
  'ar', 'en', 'es', 'fr', 'de', 'hi', 'zh-Hans', 'ja',
  'ko', 'tr', 'pt-BR', 'ru', 'th', 'id', 'ms', 'it',
  'nl', 'ur', 'fa', 'he', 'vi', 'pl', 'uk', 'el',
  'sv', 'af', 'ak', 'sq', 'am', 'hy', 'az', 'eu',
  'be', 'bn', 'bg', 'my', 'ca', 'zh-Hant', 'hr', 'cs',
  'da', 'et', 'fil', 'fi', 'gl', 'ka', 'gu', 'ha',
  'hu', 'is', 'jv', 'kn', 'kk', 'km', 'rw', 'lo',
  'lv', 'lt', 'mk', 'ml', 'mr', 'mn', 'ne', 'nb',
  'pt-PT', 'pa', 'ro', 'sr', 'sd', 'si', 'sk', 'sl',
  'su', 'sw', 'ta', 'te', 'uz', 'zu',
};

void main() {
  test('finds languages by code, case-insensitively', () {
    expect(languageForCode('ar')?.name, 'Arabic');
    expect(languageForCode('AR')?.name, 'Arabic');
    expect(languageForCode('xx'), isNull);
    expect(languageForCode(null), isNull);
    // Codes that carry a script subtag resolve whatever the casing.
    expect(languageForCode('zh-Hant')?.name, 'Chinese (Traditional)');
    expect(languageForCode('zh-hant')?.name, 'Chinese (Traditional)');
  });

  test('knows which languages are RTL', () {
    expect(isRtlLanguage('ar'), isTrue);
    expect(isRtlLanguage('he'), isTrue);
    expect(isRtlLanguage('ur'), isTrue);
    expect(isRtlLanguage('fa'), isTrue);
    expect(isRtlLanguage('sd'), isTrue);
    expect(isRtlLanguage('en'), isFalse);
    expect(isRtlLanguage('zh'), isFalse);
    // Bengali is written left-to-right.
    expect(isRtlLanguage('bn'), isFalse);
  });

  test('unknown/low-confidence detection returns null — bubble shows just "Speaker"', () {
    expect(detectedLanguageLabel('es', 0.95), 'Spanish');
    // Never a "Language detected…" placeholder anymore.
    expect(detectedLanguageLabel('es', 0.3), isNull);
    expect(detectedLanguageLabel('und', 0.99), isNull);
    expect(detectedLanguageLabel(null, 1.0), isNull);
    expect(detectedLanguageFlag('und', 0.99), isNull);
  });

  // ── Bengali / Bangla ──────────────────────────────────────────────────────

  group('Bengali', () {
    test('is a target language the user can pick', () {
      final bengali = kTargetLanguages.where((l) => l.code == 'bn');
      expect(bengali, hasLength(1),
          reason: 'bn was missing from the catalog entirely');
      expect(bengali.single.name, 'Bengali');
      expect(bengali.single.nativeName, 'বাংলা');
    });

    test('passes to Gemini as "bn" and is accepted by the server allowlist', () {
      expect(geminiCodeFor('bn'), 'bn');
      expect(_allowlist.contains(geminiCodeFor('bn')), isTrue,
          reason: 'this is the check that rejected Bengali before');
    });

    test('is displayed for a detected Bengali speaker', () {
      expect(detectedLanguageLabel('bn', 0.9), 'Bengali');
      expect(detectedLanguageFlag('bn', 0.9), '🇧🇩');
    });

    test('regional Bengali tags fold to the catalog code', () {
      // Gemini reports BCP-47; Bangladesh and India must land on one bubble
      // language, not two.
      expect(normalizeDetectedLanguage('bn-BD'), 'bn');
      expect(normalizeDetectedLanguage('bn-IN'), 'bn');
      expect(normalizeDetectedLanguage('bn'), 'bn');
    });

    test('asks the device for a Bengali voice', () {
      expect(ttsLocaleFor('bn'), 'bn-IN');
    });
  });

  // ── The languages that were silently unsupported ──────────────────────────

  group('languages that used to be missing', () {
    // Each of these is spoken by tens of millions of people, is documented as
    // supported by gemini-3.5-live-translate-preview, and could not be chosen
    // as a target before.
    const previouslyMissing = {
      'bn': 'Bengali',
      'pa': 'Punjabi',
      'mr': 'Marathi',
      'ta': 'Tamil',
      'te': 'Telugu',
      'gu': 'Gujarati',
      'kn': 'Kannada',
      'ml': 'Malayalam',
      'fil': 'Filipino',
      'sw': 'Swahili',
      'ha': 'Hausa',
      'am': 'Amharic',
      'my': 'Burmese',
      'km': 'Khmer',
      'ne': 'Nepali',
      'si': 'Sinhala',
      'ro': 'Romanian',
      'hu': 'Hungarian',
      'cs': 'Czech',
      'da': 'Danish',
      'fi': 'Finnish',
      'nb': 'Norwegian',
      'zh-Hant': 'Chinese (Traditional)',
      'pt-PT': 'Portuguese (Portugal)',
    };

    for (final entry in previouslyMissing.entries) {
      test('${entry.value} (${entry.key}) is selectable, mapped and displayable',
          () {
        final info = languageForCode(entry.key);
        expect(info, isNotNull, reason: '${entry.key} is not in the catalog');
        expect(info!.name, entry.value);
        // Reaches the model…
        expect(_allowlist.contains(geminiCodeFor(entry.key)), isTrue,
            reason: 'the server would reject ${entry.key}');
        // …and comes back displayable when DETECTED, which is the half that
        // used to leave a real speaker labelled as nothing at all.
        expect(detectedLanguageLabel(entry.key, 0.9), entry.value);
        expect(detectedLanguageFlag(entry.key, 0.9), isNotEmpty);
      });
    }
  });

  // ── The languages that already worked ─────────────────────────────────────

  test('every language that worked before still works, unchanged', () {
    // The original catalog, with the code, Gemini code and TTS locale each
    // had. Nothing here may drift: these are persisted user preferences.
    const before = {
      'ar': ('ar', 'ar-SA'),
      'en': ('en', 'en-US'),
      'es': ('es', 'es-ES'),
      'fr': ('fr', 'fr-FR'),
      'de': ('de', 'de-DE'),
      'hi': ('hi', 'hi-IN'),
      'zh': ('zh-Hans', 'zh-CN'),
      'ja': ('ja', 'ja-JP'),
      'ko': ('ko', 'ko-KR'),
      'tr': ('tr', 'tr-TR'),
      'pt': ('pt-BR', 'pt-BR'),
      'ru': ('ru', 'ru-RU'),
      'th': ('th', 'th-TH'),
      'id': ('id', 'id-ID'),
      'ms': ('ms', 'ms-MY'),
      'it': ('it', 'it-IT'),
      'nl': ('nl', 'nl-NL'),
      'ur': ('ur', 'ur-PK'),
      'fa': ('fa', 'fa-IR'),
      'he': ('he', 'he-IL'),
      'vi': ('vi', 'vi-VN'),
      'pl': ('pl', 'pl-PL'),
      'uk': ('uk', 'uk-UA'),
      'el': ('el', 'el-GR'),
      'sv': ('sv', 'sv-SE'),
    };
    for (final entry in before.entries) {
      expect(languageForCode(entry.key), isNotNull, reason: entry.key);
      expect(geminiCodeFor(entry.key), entry.value.$1, reason: entry.key);
      expect(ttsLocaleFor(entry.key), entry.value.$2, reason: entry.key);
    }
    // Arabic first — it is the flagship target language.
    expect(kTargetLanguages.first.code, 'ar');
    // The original 25 keep the head of the list, in their original order.
    expect(kTargetLanguages.take(25).map((l) => l.code).toList(),
        before.keys.toList());
  });

  test('source-language display keeps the agreed product flags', () {
    // Flags are UI representatives, not nationality claims; ar → 🇴🇲 and
    // en → 🇬🇧 are deliberate product defaults.
    expect(detectedLanguageLabel('ar', 0.9), 'Arabic');
    expect(detectedLanguageFlag('ar', 0.9), '🇴🇲');
    expect(detectedLanguageLabel('en', 0.9), 'English');
    expect(detectedLanguageFlag('en', 0.9), '🇬🇧');
    expect(detectedLanguageLabel('th', 0.9), 'Thai');
    expect(detectedLanguageFlag('th', 0.9), '🇹🇭');
    expect(detectedLanguageLabel('hi', 0.9), 'Hindi');
    expect(detectedLanguageFlag('hi', 0.9), '🇮🇳');
    expect(detectedLanguageLabel('ur', 0.9), 'Urdu');
    expect(detectedLanguageFlag('ur', 0.9), '🇵🇰');
    expect(detectedLanguageLabel('ta', 0.9), 'Tamil');
    expect(detectedLanguageFlag('ta', 0.9), '🇮🇳');
    // The picker still shows 🇸🇦 for Arabic; only DETECTION differs.
    expect(kTargetLanguages.first.flag, '🇸🇦');
    for (final entry in kSourceLanguageDisplay.entries) {
      expect(entry.value.code, entry.key);
      expect(entry.value.name, isNotEmpty);
      expect(entry.value.flag, isNotEmpty);
    }
  });

  test('geminiCodeFor maps the catalog to Gemini BCP-47 forms', () {
    expect(geminiCodeFor('zh'), 'zh-Hans');
    expect(geminiCodeFor('zh-Hant'), 'zh-Hant');
    expect(geminiCodeFor('pt'), 'pt-BR');
    expect(geminiCodeFor('pt-PT'), 'pt-PT');
    expect(geminiCodeFor('ar'), 'ar');
    expect(geminiCodeFor('EN'), 'en');
    // Unknown codes pass through; the Cloud Function is the authority.
    expect(geminiCodeFor('xx'), 'xx');
  });

  test('catalog ↔ Cloud Function allowlist parity fixture', () {
    expect(
      kTargetLanguages.map((l) => l.geminiCode).toSet(),
      _allowlist,
    );
    expect(kTargetLanguages, hasLength(_allowlist.length));
  });

  test('normalizeDetectedLanguage folds Gemini BCP-47 codes back to the catalog', () {
    expect(normalizeDetectedLanguage('pt-BR'), 'pt');
    expect(normalizeDetectedLanguage('zh-Hans'), 'zh');
    expect(normalizeDetectedLanguage('en-US'), 'en');
    expect(normalizeDetectedLanguage('ar'), 'ar');
    expect(normalizeDetectedLanguage('xx-YY'), 'xx');
    // A variant the catalog carries in its own right keeps its full tag…
    expect(normalizeDetectedLanguage('zh-Hant'), 'zh-Hant');
    expect(normalizeDetectedLanguage('zh-hant'), 'zh-Hant');
    expect(normalizeDetectedLanguage('pt-PT'), 'pt-PT');
    // …and one it does not folds to the primary subtag.
    expect(normalizeDetectedLanguage('sw-KE'), 'sw');
    expect(normalizeDetectedLanguage('fil-PH'), 'fil');
    expect(normalizeDetectedLanguage('pa_IN'), 'pa');
  });

  test('every catalog entry is complete and unique', () {
    final codes = <String>{};
    final geminiCodes = <String>{};
    for (final language in kTargetLanguages) {
      expect(language.code, isNotEmpty);
      expect(language.name, isNotEmpty);
      expect(language.nativeName, isNotEmpty);
      expect(language.flag, isNotEmpty);
      expect(language.ttsLocale, isNotEmpty);
      // A duplicate code would silently shadow a language in the picker.
      expect(codes.add(language.code.toLowerCase()), isTrue,
          reason: 'duplicate code ${language.code}');
      expect(geminiCodes.add(language.geminiCode), isTrue,
          reason: 'duplicate Gemini code ${language.geminiCode}');
      // Every row resolves back to itself through the lookup the app uses.
      expect(languageForCode(language.code)?.name,
          kSourceLanguageDisplay[language.code.toLowerCase()]?.name ??
              language.name);
    }
  });

  test('the TTS locale of every language starts with its own language tag', () {
    // A mismatched locale asks the device for the WRONG voice — the kind of
    // mapping bug that only shows up as a translation read aloud in another
    // language.
    for (final language in kTargetLanguages) {
      final primary = language.code.toLowerCase().split('-').first;
      final locale = language.ttsLocale.toLowerCase();
      if (language.code == 'zh') {
        expect(locale, 'zh-cn');
        continue;
      }
      if (language.code == 'zh-Hant') {
        expect(locale, 'zh-tw');
        continue;
      }
      expect(locale.split('-').first, primary, reason: language.code);
    }
  });
  group('finding a language in a list of 78', () {
    test('an empty query is the whole catalog, in order', () {
      expect(searchLanguages(''), kTargetLanguages);
      expect(searchLanguages('   '), kTargetLanguages);
    });

    test('Bengali is findable by every name its speakers use', () {
      for (final query in ['Bengali', 'bengali', 'বাংলা', 'Bangla', 'bangla', 'bn']) {
        expect(searchLanguages(query).map((l) => l.code), contains('bn'),
            reason: 'searching "$query" must find Bengali');
      }
    });

    test('other languages people know by a second name', () {
      expect(searchLanguages('Farsi').single.code, 'fa');
      expect(searchLanguages('Tagalog').single.code, 'fil');
      expect(searchLanguages('Mandarin').single.code, 'zh');
      expect(searchLanguages('Myanmar').single.code, 'my');
      expect(searchLanguages('Panjabi').single.code, 'pa');
    });

    test('a native-script query finds its language', () {
      expect(searchLanguages('العربية').first.code, 'ar');
      expect(searchLanguages('தமிழ்').single.code, 'ta');
      expect(searchLanguages('ελλ').single.code, 'el');
    });

    test('a query that matches nothing returns nothing', () {
      expect(searchLanguages('klingon'), isEmpty);
    });
  });
}
