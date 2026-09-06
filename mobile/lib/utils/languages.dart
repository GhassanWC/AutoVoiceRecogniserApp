/// Catalog of target languages the user can pick, plus display metadata for
/// any language the recognizer may detect. Detection is never limited to this
/// list — unknown codes simply render without a flag.
class LanguageInfo {
  const LanguageInfo({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.flag,
    this.isRtl = false,
  });

  /// ISO 639-1 code, e.g. "ar".
  final String code;

  /// English name, e.g. "Arabic".
  final String name;

  /// Name in the language itself, e.g. "العربية".
  final String nativeName;

  /// Emoji flag used as a compact visual cue (not a nationality claim).
  final String flag;

  final bool isRtl;
}

const List<LanguageInfo> kTargetLanguages = [
  LanguageInfo(code: 'ar', name: 'Arabic', nativeName: 'العربية', flag: '🇸🇦', isRtl: true),
  LanguageInfo(code: 'en', name: 'English', nativeName: 'English', flag: '🇬🇧'),
  LanguageInfo(code: 'es', name: 'Spanish', nativeName: 'Español', flag: '🇪🇸'),
  LanguageInfo(code: 'fr', name: 'French', nativeName: 'Français', flag: '🇫🇷'),
  LanguageInfo(code: 'de', name: 'German', nativeName: 'Deutsch', flag: '🇩🇪'),
  LanguageInfo(code: 'hi', name: 'Hindi', nativeName: 'हिन्दी', flag: '🇮🇳'),
  LanguageInfo(code: 'zh', name: 'Chinese', nativeName: '中文', flag: '🇨🇳'),
  LanguageInfo(code: 'ja', name: 'Japanese', nativeName: '日本語', flag: '🇯🇵'),
  LanguageInfo(code: 'ko', name: 'Korean', nativeName: '한국어', flag: '🇰🇷'),
  LanguageInfo(code: 'tr', name: 'Turkish', nativeName: 'Türkçe', flag: '🇹🇷'),
  LanguageInfo(code: 'pt', name: 'Portuguese', nativeName: 'Português', flag: '🇵🇹'),
  LanguageInfo(code: 'ru', name: 'Russian', nativeName: 'Русский', flag: '🇷🇺'),
  LanguageInfo(code: 'th', name: 'Thai', nativeName: 'ไทย', flag: '🇹🇭'),
  LanguageInfo(code: 'id', name: 'Indonesian', nativeName: 'Bahasa Indonesia', flag: '🇮🇩'),
  LanguageInfo(code: 'ms', name: 'Malay', nativeName: 'Bahasa Melayu', flag: '🇲🇾'),
  LanguageInfo(code: 'it', name: 'Italian', nativeName: 'Italiano', flag: '🇮🇹'),
  LanguageInfo(code: 'nl', name: 'Dutch', nativeName: 'Nederlands', flag: '🇳🇱'),
  LanguageInfo(code: 'ur', name: 'Urdu', nativeName: 'اردو', flag: '🇵🇰', isRtl: true),
  LanguageInfo(code: 'fa', name: 'Persian', nativeName: 'فارسی', flag: '🇮🇷', isRtl: true),
  LanguageInfo(code: 'he', name: 'Hebrew', nativeName: 'עברית', flag: '🇮🇱', isRtl: true),
  LanguageInfo(code: 'vi', name: 'Vietnamese', nativeName: 'Tiếng Việt', flag: '🇻🇳'),
  LanguageInfo(code: 'pl', name: 'Polish', nativeName: 'Polski', flag: '🇵🇱'),
  LanguageInfo(code: 'uk', name: 'Ukrainian', nativeName: 'Українська', flag: '🇺🇦'),
  LanguageInfo(code: 'el', name: 'Greek', nativeName: 'Ελληνικά', flag: '🇬🇷'),
  LanguageInfo(code: 'sv', name: 'Swedish', nativeName: 'Svenska', flag: '🇸🇪'),
];

/// THE centralized display mapping for detected SOURCE languages
/// (ISO 639-1 → English name + flag), kept in sync with the backend's
/// language_detected event names.
///
/// Flags are UI representatives only — a language is not a nationality, and
/// many of these languages span dozens of countries. Product defaults:
/// Arabic shows 🇴🇲 (the app's current Omani user base) and English shows 🇬🇧
/// until locale/accent detection exists.
const Map<String, LanguageInfo> kSourceLanguageDisplay = {
  'en': LanguageInfo(code: 'en', name: 'English', nativeName: 'English', flag: '🇬🇧'),
  'ar': LanguageInfo(code: 'ar', name: 'Arabic', nativeName: 'العربية', flag: '🇴🇲', isRtl: true),
  'th': LanguageInfo(code: 'th', name: 'Thai', nativeName: 'ไทย', flag: '🇹🇭'),
  'bn': LanguageInfo(code: 'bn', name: 'Bengali', nativeName: 'বাংলা', flag: '🇧🇩'),
  'hi': LanguageInfo(code: 'hi', name: 'Hindi', nativeName: 'हिन्दी', flag: '🇮🇳'),
  'ur': LanguageInfo(code: 'ur', name: 'Urdu', nativeName: 'اردو', flag: '🇵🇰', isRtl: true),
  'ta': LanguageInfo(code: 'ta', name: 'Tamil', nativeName: 'தமிழ்', flag: '🇮🇳'),
  'te': LanguageInfo(code: 'te', name: 'Telugu', nativeName: 'తెలుగు', flag: '🇮🇳'),
  'ml': LanguageInfo(code: 'ml', name: 'Malayalam', nativeName: 'മലയാളം', flag: '🇮🇳'),
  'es': LanguageInfo(code: 'es', name: 'Spanish', nativeName: 'Español', flag: '🇪🇸'),
  'fr': LanguageInfo(code: 'fr', name: 'French', nativeName: 'Français', flag: '🇫🇷'),
  'de': LanguageInfo(code: 'de', name: 'German', nativeName: 'Deutsch', flag: '🇩🇪'),
  'ja': LanguageInfo(code: 'ja', name: 'Japanese', nativeName: '日本語', flag: '🇯🇵'),
  'ko': LanguageInfo(code: 'ko', name: 'Korean', nativeName: '한국어', flag: '🇰🇷'),
  'id': LanguageInfo(
      code: 'id', name: 'Indonesian', nativeName: 'Bahasa Indonesia', flag: '🇮🇩'),
  'zh': LanguageInfo(code: 'zh', name: 'Chinese', nativeName: '中文', flag: '🇨🇳'),
  'ru': LanguageInfo(code: 'ru', name: 'Russian', nativeName: 'Русский', flag: '🇷🇺'),
  'pt': LanguageInfo(code: 'pt', name: 'Portuguese', nativeName: 'Português', flag: '🇵🇹'),
};

final Map<String, LanguageInfo> _byCode = {
  for (final language in kTargetLanguages) language.code: language,
};

LanguageInfo? languageForCode(String? code) {
  if (code == null) return null;
  final lower = code.toLowerCase();
  return kSourceLanguageDisplay[lower] ?? _byCode[lower];
}

bool isRtlLanguage(String code) => languageForCode(code)?.isRtl ?? false;

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
