/// THE language catalog for Sayvo — one row per language, carrying every
/// mapping that language needs anywhere in the app.
///
/// One row, four mappings: what the picker shows ([name], [nativeName],
/// [flag], [isRtl]), what the app stores ([code]), what Gemini is asked for
/// ([geminiCode]), and which voice the device is asked for ([ttsLocale]).
/// They used to live in four separate switch statements that could — and did
/// — disagree; keeping them on one row is what makes a mapping bug visible at
/// review time instead of at runtime.
///
/// Scope: the languages `gemini-3.5-live-translate-preview` documents support
/// for. The model detects the SOURCE language itself, per utterance, and is
/// never told what to listen for — this catalog governs what the user can
/// translate INTO, plus how a detected language is displayed.
///
/// KEPT IN LOCKSTEP with functions/src/languages.ts (the server-side
/// validation set). mobile/test/languages_test.dart and languages.test.ts
/// pin the parity in both directions — update both files together.
class LanguageInfo {
  const LanguageInfo({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.flag,
    this.isRtl = false,
    String? geminiCode,
    String? ttsLocale,
    this.aliases = const [],
  })  : _geminiCode = geminiCode,
        _ttsLocale = ttsLocale;

  /// The code Sayvo stores and passes around — ISO 639-1 where one exists
  /// ("ar", "bn"), otherwise the tag the model uses ("fil", "zh-Hant").
  ///
  /// This is a PERSISTED value (settings and users/{uid}.targetLanguageCode),
  /// so an existing code may never be renamed: "zh" and "pt" predate the
  /// Simplified/Traditional and Brazil/Portugal split and keep their original
  /// meaning.
  final String code;

  /// English name, e.g. "Bengali".
  final String name;

  /// Name in the language itself, e.g. "বাংলা".
  final String nativeName;

  /// Emoji flag used as a compact visual cue (not a nationality claim).
  final String flag;

  final bool isRtl;

  /// Other names people search for this language by. Bengali speakers type
  /// "Bangla", Persian speakers type "Farsi" — without these the language is
  /// in the list and still unfindable.
  final List<String> aliases;

  final String? _geminiCode;
  final String? _ttsLocale;

  /// BCP-47 code for the Gemini Live Translate `targetLanguageCode`. Equal to
  /// [code] unless the model spells it differently.
  String get geminiCode => _geminiCode ?? code;

  /// BCP-47 locale for the device speech synthesizer. Gemini's codes are not
  /// always usable voice locales ("zh-Hans" is a script tag, not a locale) and
  /// a bare tag leaves the voice up to the platform, so each row names a
  /// region whose voice commonly ships. Both platforms fall back to the
  /// primary subtag when that exact voice is absent, and the UI says so when
  /// there is no voice at all.
  String get ttsLocale => _ttsLocale ?? code;
}

/// Every language the app can translate into.
///
/// Order is deliberate, not alphabetical: the languages Sayvo was built around
/// stay at the top where they have always been, and the rest follow
/// alphabetically by English name. The picker searches by English name, native
/// name and code, so position matters only for the first screenful.
const List<LanguageInfo> kTargetLanguages = [
  // ── The original product languages, in their established order ───────────
  LanguageInfo(code: 'ar', name: 'Arabic', nativeName: 'العربية', flag: '🇸🇦', isRtl: true, ttsLocale: 'ar-SA'),
  LanguageInfo(code: 'en', name: 'English', nativeName: 'English', flag: '🇬🇧', ttsLocale: 'en-US'),
  LanguageInfo(code: 'es', name: 'Spanish', nativeName: 'Español', flag: '🇪🇸', ttsLocale: 'es-ES'),
  LanguageInfo(code: 'fr', name: 'French', nativeName: 'Français', flag: '🇫🇷', ttsLocale: 'fr-FR'),
  LanguageInfo(code: 'de', name: 'German', nativeName: 'Deutsch', flag: '🇩🇪', ttsLocale: 'de-DE'),
  LanguageInfo(code: 'hi', name: 'Hindi', nativeName: 'हिन्दी', flag: '🇮🇳', ttsLocale: 'hi-IN'),
  LanguageInfo(code: 'zh', name: 'Chinese (Simplified)', nativeName: '简体中文', flag: '🇨🇳', geminiCode: 'zh-Hans', ttsLocale: 'zh-CN', aliases: ['Mandarin']),
  LanguageInfo(code: 'ja', name: 'Japanese', nativeName: '日本語', flag: '🇯🇵', ttsLocale: 'ja-JP'),
  LanguageInfo(code: 'ko', name: 'Korean', nativeName: '한국어', flag: '🇰🇷', ttsLocale: 'ko-KR'),
  LanguageInfo(code: 'tr', name: 'Turkish', nativeName: 'Türkçe', flag: '🇹🇷', ttsLocale: 'tr-TR'),
  LanguageInfo(code: 'pt', name: 'Portuguese (Brazil)', nativeName: 'Português (Brasil)', flag: '🇧🇷', geminiCode: 'pt-BR', ttsLocale: 'pt-BR'),
  LanguageInfo(code: 'ru', name: 'Russian', nativeName: 'Русский', flag: '🇷🇺', ttsLocale: 'ru-RU'),
  LanguageInfo(code: 'th', name: 'Thai', nativeName: 'ไทย', flag: '🇹🇭', ttsLocale: 'th-TH'),
  LanguageInfo(code: 'id', name: 'Indonesian', nativeName: 'Bahasa Indonesia', flag: '🇮🇩', ttsLocale: 'id-ID'),
  LanguageInfo(code: 'ms', name: 'Malay', nativeName: 'Bahasa Melayu', flag: '🇲🇾', ttsLocale: 'ms-MY'),
  LanguageInfo(code: 'it', name: 'Italian', nativeName: 'Italiano', flag: '🇮🇹', ttsLocale: 'it-IT'),
  LanguageInfo(code: 'nl', name: 'Dutch', nativeName: 'Nederlands', flag: '🇳🇱', ttsLocale: 'nl-NL', aliases: ['Flemish']),
  LanguageInfo(code: 'ur', name: 'Urdu', nativeName: 'اردو', flag: '🇵🇰', isRtl: true, ttsLocale: 'ur-PK'),
  LanguageInfo(code: 'fa', name: 'Persian', nativeName: 'فارسی', flag: '🇮🇷', isRtl: true, ttsLocale: 'fa-IR', aliases: ['Farsi']),
  LanguageInfo(code: 'he', name: 'Hebrew', nativeName: 'עברית', flag: '🇮🇱', isRtl: true, ttsLocale: 'he-IL'),
  LanguageInfo(code: 'vi', name: 'Vietnamese', nativeName: 'Tiếng Việt', flag: '🇻🇳', ttsLocale: 'vi-VN'),
  LanguageInfo(code: 'pl', name: 'Polish', nativeName: 'Polski', flag: '🇵🇱', ttsLocale: 'pl-PL'),
  LanguageInfo(code: 'uk', name: 'Ukrainian', nativeName: 'Українська', flag: '🇺🇦', ttsLocale: 'uk-UA'),
  LanguageInfo(code: 'el', name: 'Greek', nativeName: 'Ελληνικά', flag: '🇬🇷', ttsLocale: 'el-GR'),
  LanguageInfo(code: 'sv', name: 'Swedish', nativeName: 'Svenska', flag: '🇸🇪', ttsLocale: 'sv-SE'),

  // ── Everything else the model supports, A→Z by English name ──────────────
  LanguageInfo(code: 'af', name: 'Afrikaans', nativeName: 'Afrikaans', flag: '🇿🇦', ttsLocale: 'af-ZA'),
  LanguageInfo(code: 'ak', name: 'Akan', nativeName: 'Akan', flag: '🇬🇭', ttsLocale: 'ak-GH'),
  LanguageInfo(code: 'sq', name: 'Albanian', nativeName: 'Shqip', flag: '🇦🇱', ttsLocale: 'sq-AL'),
  LanguageInfo(code: 'am', name: 'Amharic', nativeName: 'አማርኛ', flag: '🇪🇹', ttsLocale: 'am-ET'),
  LanguageInfo(code: 'hy', name: 'Armenian', nativeName: 'Հայերեն', flag: '🇦🇲', ttsLocale: 'hy-AM'),
  LanguageInfo(code: 'az', name: 'Azerbaijani', nativeName: 'Azərbaycan dili', flag: '🇦🇿', ttsLocale: 'az-AZ'),
  LanguageInfo(code: 'eu', name: 'Basque', nativeName: 'Euskara', flag: '🇪🇸', ttsLocale: 'eu-ES'),
  LanguageInfo(code: 'be', name: 'Belarusian', nativeName: 'Беларуская', flag: '🇧🇾', ttsLocale: 'be-BY'),
  LanguageInfo(code: 'bn', name: 'Bengali', nativeName: 'বাংলা', flag: '🇧🇩', ttsLocale: 'bn-IN', aliases: ['Bangla']),
  LanguageInfo(code: 'bg', name: 'Bulgarian', nativeName: 'Български', flag: '🇧🇬', ttsLocale: 'bg-BG'),
  LanguageInfo(code: 'my', name: 'Burmese', nativeName: 'မြန်မာ', flag: '🇲🇲', ttsLocale: 'my-MM', aliases: ['Myanmar']),
  // Andorra, where Catalan is the sole official language — there is no
  // Catalonia emoji, and 🇪🇸 would be the wrong claim to make.
  LanguageInfo(code: 'ca', name: 'Catalan', nativeName: 'Català', flag: '🇦🇩', ttsLocale: 'ca-ES'),
  LanguageInfo(code: 'zh-Hant', name: 'Chinese (Traditional)', nativeName: '繁體中文', flag: '🇹🇼', ttsLocale: 'zh-TW'),
  LanguageInfo(code: 'hr', name: 'Croatian', nativeName: 'Hrvatski', flag: '🇭🇷', ttsLocale: 'hr-HR'),
  LanguageInfo(code: 'cs', name: 'Czech', nativeName: 'Čeština', flag: '🇨🇿', ttsLocale: 'cs-CZ'),
  LanguageInfo(code: 'da', name: 'Danish', nativeName: 'Dansk', flag: '🇩🇰', ttsLocale: 'da-DK'),
  LanguageInfo(code: 'et', name: 'Estonian', nativeName: 'Eesti', flag: '🇪🇪', ttsLocale: 'et-EE'),
  LanguageInfo(code: 'fil', name: 'Filipino', nativeName: 'Filipino', flag: '🇵🇭', ttsLocale: 'fil-PH', aliases: ['Tagalog']),
  LanguageInfo(code: 'fi', name: 'Finnish', nativeName: 'Suomi', flag: '🇫🇮', ttsLocale: 'fi-FI'),
  LanguageInfo(code: 'gl', name: 'Galician', nativeName: 'Galego', flag: '🇪🇸', ttsLocale: 'gl-ES'),
  LanguageInfo(code: 'ka', name: 'Georgian', nativeName: 'ქართული', flag: '🇬🇪', ttsLocale: 'ka-GE'),
  LanguageInfo(code: 'gu', name: 'Gujarati', nativeName: 'ગુજરાતી', flag: '🇮🇳', ttsLocale: 'gu-IN'),
  LanguageInfo(code: 'ha', name: 'Hausa', nativeName: 'Hausa', flag: '🇳🇬', ttsLocale: 'ha-NG'),
  LanguageInfo(code: 'hu', name: 'Hungarian', nativeName: 'Magyar', flag: '🇭🇺', ttsLocale: 'hu-HU'),
  LanguageInfo(code: 'is', name: 'Icelandic', nativeName: 'Íslenska', flag: '🇮🇸', ttsLocale: 'is-IS'),
  LanguageInfo(code: 'jv', name: 'Javanese', nativeName: 'Basa Jawa', flag: '🇮🇩', ttsLocale: 'jv-ID'),
  LanguageInfo(code: 'kn', name: 'Kannada', nativeName: 'ಕನ್ನಡ', flag: '🇮🇳', ttsLocale: 'kn-IN'),
  LanguageInfo(code: 'kk', name: 'Kazakh', nativeName: 'Қазақ тілі', flag: '🇰🇿', ttsLocale: 'kk-KZ'),
  LanguageInfo(code: 'km', name: 'Khmer', nativeName: 'ខ្មែរ', flag: '🇰🇭', ttsLocale: 'km-KH'),
  LanguageInfo(code: 'rw', name: 'Kinyarwanda', nativeName: 'Ikinyarwanda', flag: '🇷🇼', ttsLocale: 'rw-RW'),
  LanguageInfo(code: 'lo', name: 'Lao', nativeName: 'ລາວ', flag: '🇱🇦', ttsLocale: 'lo-LA'),
  LanguageInfo(code: 'lv', name: 'Latvian', nativeName: 'Latviešu', flag: '🇱🇻', ttsLocale: 'lv-LV'),
  LanguageInfo(code: 'lt', name: 'Lithuanian', nativeName: 'Lietuvių', flag: '🇱🇹', ttsLocale: 'lt-LT'),
  LanguageInfo(code: 'mk', name: 'Macedonian', nativeName: 'Македонски', flag: '🇲🇰', ttsLocale: 'mk-MK'),
  LanguageInfo(code: 'ml', name: 'Malayalam', nativeName: 'മലയാളം', flag: '🇮🇳', ttsLocale: 'ml-IN'),
  LanguageInfo(code: 'mr', name: 'Marathi', nativeName: 'मराठी', flag: '🇮🇳', ttsLocale: 'mr-IN'),
  LanguageInfo(code: 'mn', name: 'Mongolian', nativeName: 'Монгол', flag: '🇲🇳', ttsLocale: 'mn-MN'),
  LanguageInfo(code: 'ne', name: 'Nepali', nativeName: 'नेपाली', flag: '🇳🇵', ttsLocale: 'ne-NP'),
  LanguageInfo(code: 'nb', name: 'Norwegian', nativeName: 'Norsk', flag: '🇳🇴', ttsLocale: 'nb-NO', aliases: ['Bokmal', 'Norwegian Bokmal']),
  LanguageInfo(code: 'pt-PT', name: 'Portuguese (Portugal)', nativeName: 'Português (Portugal)', flag: '🇵🇹', ttsLocale: 'pt-PT'),
  LanguageInfo(code: 'pa', name: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ', flag: '🇮🇳', ttsLocale: 'pa-IN', aliases: ['Panjabi']),
  LanguageInfo(code: 'ro', name: 'Romanian', nativeName: 'Română', flag: '🇷🇴', ttsLocale: 'ro-RO'),
  LanguageInfo(code: 'sr', name: 'Serbian', nativeName: 'Српски', flag: '🇷🇸', ttsLocale: 'sr-RS'),
  LanguageInfo(code: 'sd', name: 'Sindhi', nativeName: 'سنڌي', flag: '🇵🇰', isRtl: true, ttsLocale: 'sd-PK'),
  LanguageInfo(code: 'si', name: 'Sinhala', nativeName: 'සිංහල', flag: '🇱🇰', ttsLocale: 'si-LK'),
  LanguageInfo(code: 'sk', name: 'Slovak', nativeName: 'Slovenčina', flag: '🇸🇰', ttsLocale: 'sk-SK'),
  LanguageInfo(code: 'sl', name: 'Slovenian', nativeName: 'Slovenščina', flag: '🇸🇮', ttsLocale: 'sl-SI'),
  LanguageInfo(code: 'su', name: 'Sundanese', nativeName: 'Basa Sunda', flag: '🇮🇩', ttsLocale: 'su-ID'),
  LanguageInfo(code: 'sw', name: 'Swahili', nativeName: 'Kiswahili', flag: '🇰🇪', ttsLocale: 'sw-KE'),
  LanguageInfo(code: 'ta', name: 'Tamil', nativeName: 'தமிழ்', flag: '🇮🇳', ttsLocale: 'ta-IN'),
  LanguageInfo(code: 'te', name: 'Telugu', nativeName: 'తెలుగు', flag: '🇮🇳', ttsLocale: 'te-IN'),
  LanguageInfo(code: 'uz', name: 'Uzbek', nativeName: 'Oʻzbekcha', flag: '🇺🇿', ttsLocale: 'uz-UZ'),
  LanguageInfo(code: 'zu', name: 'Zulu', nativeName: 'isiZulu', flag: '🇿🇦', ttsLocale: 'zu-ZA'),
];

/// Flags shown for a DETECTED source language where the product deliberately
/// differs from the picker's.
///
/// Arabic is the only one: the picker offers 🇸🇦 for the language, while a
/// detected Arabic speaker is shown 🇴🇲 for the app's current Omani user base.
/// Everything else comes from [kTargetLanguages], so there is no second list
/// to drift — which is what used to leave a detected Punjabi or Swahili
/// speaker with no name and no flag at all.
const Map<String, LanguageInfo> kSourceLanguageDisplay = {
  'ar': LanguageInfo(code: 'ar', name: 'Arabic', nativeName: 'العربية', flag: '🇴🇲', isRtl: true, ttsLocale: 'ar-SA'),
};

final Map<String, LanguageInfo> _byCode = {
  for (final language in kTargetLanguages) language.code.toLowerCase(): language,
};

LanguageInfo? languageForCode(String? code) {
  if (code == null) return null;
  final lower = code.toLowerCase();
  return kSourceLanguageDisplay[lower] ?? _byCode[lower];
}

bool isRtlLanguage(String code) => languageForCode(code)?.isRtl ?? false;

/// Maps a catalog code to the BCP-47 form the Gemini Live Translate API
/// expects. Unknown codes pass through unchanged — the Cloud Function is the
/// authority and rejects anything outside its own set.
String geminiCodeFor(String iso639) =>
    _byCode[iso639.toLowerCase()]?.geminiCode ?? iso639.toLowerCase();

/// BCP-47 locale for the device speech synthesizer. Unknown codes fall through
/// unchanged and the synthesizer decides.
String ttsLocaleFor(String iso639) =>
    _byCode[iso639.toLowerCase()]?.ttsLocale ?? iso639.toLowerCase();

/// Normalizes a language code reported by Gemini (BCP-47, e.g. "pt-BR",
/// "zh-Hans", "en-US", "bn-BD") to the catalog's own code, so a detected
/// language and a picked one are the same string.
///
/// A regional variant the catalog does not carry separately folds to its
/// primary subtag ("bn-BD" → "bn"); one it does keeps its full tag
/// ("zh-Hant"). Unknown codes fall back to the primary subtag and simply
/// render without a name.
String normalizeDetectedLanguage(String code) {
  final exact = _byCode[code.toLowerCase()];
  if (exact != null) return exact.code;
  final primary = code.toLowerCase().split(RegExp('[-_]')).first;
  return _byCode[primary]?.code ?? primary;
}

/// Display name for a detected source language, or null while the language is
/// unknown/low-confidence — the bubble then shows just "Speaker". Never a
/// literal "Language detected…" placeholder.
String? detectedLanguageLabel(String? code, double confidence) {
  final info = languageForCode(code);
  if (code == null || code == 'und' || confidence < 0.5 || info == null) {
    return null;
  }
  return info.name;
}

String? detectedLanguageFlag(String? code, double confidence) {
  if (code == null || confidence < 0.5) return null;
  return languageForCode(code)?.flag;
}

/// The one language-search used by every picker in the app.
///
/// Matches English name, native name, code and the alternate names people
/// actually type. Case-insensitive; an empty query is the whole catalog in
/// its curated order.
List<LanguageInfo> searchLanguages(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return kTargetLanguages;
  return [
    for (final language in kTargetLanguages)
      if (language.name.toLowerCase().contains(q) ||
          language.nativeName.toLowerCase().contains(q) ||
          language.code.toLowerCase() == q ||
          language.aliases.any((a) => a.toLowerCase().contains(q)))
        language,
  ];
}
