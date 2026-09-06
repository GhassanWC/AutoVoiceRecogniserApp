import { describe, expect, it } from 'vitest';
import { detectLanguageByScript, LANGUAGE_NAMES } from '../src/utils/language_detect';

describe('detectLanguageByScript', () => {
  it('identifies unique-script languages instantly', () => {
    expect(detectLanguageByScript('สวัสดีครับ')).toBe('th'); // Thai
    expect(detectLanguageByScript('আসসালামু আলাইকুম')).toBe('bn'); // Bengali
    expect(detectLanguageByScript('नमस्ते, आप कैसे हैं?')).toBe('hi'); // Devanagari
    expect(detectLanguageByScript('வணக்கம்')).toBe('ta'); // Tamil
    expect(detectLanguageByScript('తెలుగు మాట్లాడతాను')).toBe('te'); // Telugu
    expect(detectLanguageByScript('മലയാളം സംസാരിക്കുന്നു')).toBe('ml'); // Malayalam
    expect(detectLanguageByScript('안녕하세요')).toBe('ko'); // Hangul
    expect(detectLanguageByScript('こんにちは、元気ですか')).toBe('ja'); // kana wins
    expect(detectLanguageByScript('你好吗')).toBe('zh'); // Han without kana
    expect(detectLanguageByScript('Привет, как дела?')).toBe('ru'); // Cyrillic
    expect(detectLanguageByScript('السلام عليكم')).toBe('ar'); // Arabic script
  });

  it('separates Urdu from Arabic via its distinctive letters', () => {
    expect(detectLanguageByScript('آپ کیسے ہیں؟')).toBe('ur');
    expect(detectLanguageByScript('كيف حالك يا أخي')).toBe('ar');
  });

  it('returns null for Latin script and unusable input (model detector takes over)', () => {
    expect(detectLanguageByScript('Hello, how are you?')).toBeNull();
    expect(detectLanguageByScript('Hola hermano')).toBeNull();
    expect(detectLanguageByScript('12345 …!!')).toBeNull();
    expect(detectLanguageByScript('')).toBeNull();
  });

  it('has display names for every product language', () => {
    for (const code of ['en', 'ar', 'th', 'bn', 'hi', 'ur', 'ta', 'te', 'ml', 'es', 'fr', 'de', 'ja', 'ko', 'id', 'zh', 'ru', 'pt']) {
      expect(LANGUAGE_NAMES[code], code).toBeTruthy();
    }
    expect(LANGUAGE_NAMES['th']).toBe('Thai');
    expect(LANGUAGE_NAMES['bn']).toBe('Bengali');
    expect(LANGUAGE_NAMES['ar']).toBe('Arabic');
  });
});
