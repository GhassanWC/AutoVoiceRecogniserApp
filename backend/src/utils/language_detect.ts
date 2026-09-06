import { log } from './logger';

/**
 * Source-language identification for the language LABEL only. This is pure
 * metadata: it runs after (never before) translated text is already on its
 * way to the user, so nothing here may sit in the delta path.
 *
 * Two tiers:
 *  1. Script analysis — free, instant, and unambiguous for languages with a
 *     (near-)unique script: Thai, Bengali, Devanagari, Tamil, Telugu,
 *     Malayalam, Korean, Japanese kana, Han, Cyrillic, Greek, Hebrew, and
 *     Arabic script (Urdu separated by its distinctive letters).
 *  2. A tiny model call (gpt-4o-mini, a few tokens) for Latin-script text,
 *     where the script alone cannot tell English from Spanish etc.
 */

/** Display names for the language_detected event (mirrors the app's map). */
export const LANGUAGE_NAMES: Record<string, string> = {
  en: 'English',
  ar: 'Arabic',
  th: 'Thai',
  bn: 'Bengali',
  hi: 'Hindi',
  ur: 'Urdu',
  ta: 'Tamil',
  te: 'Telugu',
  ml: 'Malayalam',
  es: 'Spanish',
  fr: 'French',
  de: 'German',
  ja: 'Japanese',
  ko: 'Korean',
  id: 'Indonesian',
  zh: 'Chinese',
  ru: 'Russian',
  pt: 'Portuguese',
  el: 'Greek',
  he: 'Hebrew',
  fa: 'Persian',
  tr: 'Turkish',
  it: 'Italian',
  nl: 'Dutch',
  vi: 'Vietnamese',
};

/** Letters unique to Urdu orthography (Arabic script otherwise). */
const URDU_MARKERS = /[ٹڈڑںھہے]/;

const SCRIPTS: Array<{ code: string; pattern: RegExp }> = [
  { code: 'th', pattern: /[฀-๿]/ },
  { code: 'bn', pattern: /[ঀ-৿]/ },
  { code: 'hi', pattern: /[ऀ-ॿ]/ }, // Devanagari — Hindi as UI default
  { code: 'ta', pattern: /[஀-௿]/ },
  { code: 'te', pattern: /[ఀ-౿]/ },
  { code: 'ml', pattern: /[ഀ-ൿ]/ },
  { code: 'ko', pattern: /[가-힯ᄀ-ᇿ]/ },
  { code: 'ja', pattern: /[぀-ヿ]/ }, // kana — unambiguously Japanese
  { code: 'zh', pattern: /[一-鿿]/ }, // Han without kana → Chinese
  { code: 'ru', pattern: /[Ѐ-ӿ]/ }, // Cyrillic — Russian as UI default
  { code: 'el', pattern: /[Ͱ-Ͽ]/ },
  { code: 'he', pattern: /[֐-׿]/ },
  { code: 'ar', pattern: /[؀-ۿݐ-ݿ]/ },
];

/**
 * Identify the language from its script alone. Returns null when the script
 * is shared by many languages (Latin) or the text is too short/mixed —
 * callers then fall back to the model detector.
 */
export function detectLanguageByScript(text: string): string | null {
  const counts = new Map<string, number>();
  let scriptLetters = 0;
  for (const char of text) {
    for (const { code, pattern } of SCRIPTS) {
      if (pattern.test(char)) {
        counts.set(code, (counts.get(code) ?? 0) + 1);
        scriptLetters += 1;
        break;
      }
    }
  }
  if (scriptLetters < 2) return null;

  let best: string | null = null;
  let bestCount = 0;
  for (const [code, count] of counts) {
    if (count > bestCount) {
      best = code;
      bestCount = count;
    }
  }
  // Japanese text mixes kana and Han — any kana at all wins over "zh".
  if (best === 'zh' && (counts.get('ja') ?? 0) > 0) best = 'ja';
  // Urdu shares the Arabic script; its unique letters decide.
  if (best === 'ar' && URDU_MARKERS.test(text)) best = 'ur';
  // Require a clear majority so mixed snippets do not get a confident flag.
  if (best && bestCount / scriptLetters >= 0.5) return best;
  return null;
}

const DETECT_TIMEOUT_MS = 5_000;

export type LanguageDetector = (text: string) => Promise<string>;

/**
 * Tiny model-based detector for scripts shared across languages (Latin).
 * A few tokens per call; failures resolve to "und" — a missing label must
 * never surface an error.
 */
export function createModelLanguageDetector(
  apiKey: string,
  model = 'gpt-4o-mini',
): LanguageDetector {
  return async (text: string): Promise<string> => {
    try {
      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          temperature: 0,
          max_tokens: 5,
          messages: [
            {
              role: 'system',
              content:
                'Identify the language of the user text. Reply with ONLY its ISO 639-1 code (e.g. en, es, id), or "und" if genuinely unsure.',
            },
            { role: 'user', content: text.slice(0, 300) },
          ],
        }),
        signal: AbortSignal.timeout(DETECT_TIMEOUT_MS),
      });
      if (!response.ok) return 'und';
      const json = (await response.json()) as {
        choices?: Array<{ message?: { content?: string } }>;
      };
      const code = (json.choices?.[0]?.message?.content ?? '')
        .trim()
        .toLowerCase()
        .replace(/[^a-z]/g, '');
      return /^[a-z]{2,3}$/.test(code) ? code : 'und';
    } catch (error) {
      log.debug('language detection call failed', {
        message: error instanceof Error ? error.message : String(error),
      });
      return 'und';
    }
  };
}
