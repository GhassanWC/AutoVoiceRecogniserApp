/// On-device script-based language identification — the offline counterpart
/// of the backend's detector, used as a backup when Whisper's own language
/// result is missing/unreliable. Unique-script languages only; Latin-script
/// text stays null (Whisper's verdict is then trusted as-is).
library;

final RegExp _urduMarkers = RegExp(r'[ٹڈڑںھہے]');

final List<({String code, RegExp pattern})> _scripts = [
  (code: 'th', pattern: RegExp(r'[฀-๿]')),
  (code: 'bn', pattern: RegExp(r'[ঀ-৿]')),
  (code: 'hi', pattern: RegExp(r'[ऀ-ॿ]')),
  (code: 'ta', pattern: RegExp(r'[஀-௿]')),
  (code: 'te', pattern: RegExp(r'[ఀ-౿]')),
  (code: 'ml', pattern: RegExp(r'[ഀ-ൿ]')),
  (code: 'ko', pattern: RegExp(r'[가-힯ᄀ-ᇿ]')),
  (code: 'ja', pattern: RegExp(r'[぀-ヿ]')),
  (code: 'zh', pattern: RegExp(r'[一-鿿]')),
  (code: 'ru', pattern: RegExp(r'[Ѐ-ӿ]')),
  (code: 'el', pattern: RegExp(r'[Ͱ-Ͽ]')),
  (code: 'he', pattern: RegExp(r'[֐-׿]')),
  (code: 'ar', pattern: RegExp(r'[؀-ۿݐ-ݿ]')),
];

String? detectLanguageByScript(String text) {
  final counts = <String, int>{};
  var scriptLetters = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    for (final script in _scripts) {
      if (script.pattern.hasMatch(char)) {
        counts[script.code] = (counts[script.code] ?? 0) + 1;
        scriptLetters++;
        break;
      }
    }
  }
  if (scriptLetters < 2) return null;

  String? best;
  var bestCount = 0;
  counts.forEach((code, count) {
    if (count > bestCount) {
      best = code;
      bestCount = count;
    }
  });
  // Japanese mixes kana and Han — any kana wins over "zh".
  if (best == 'zh' && (counts['ja'] ?? 0) > 0) best = 'ja';
  // Urdu shares the Arabic script; its unique letters decide.
  if (best == 'ar' && _urduMarkers.hasMatch(text)) best = 'ur';
  if (best != null && bestCount / scriptLetters >= 0.5) return best;
  return null;
}
