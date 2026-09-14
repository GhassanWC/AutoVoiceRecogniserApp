/**
 * Server-side allowlist of target languages, in the BCP-47 form the Gemini
 * Live Translate API expects.
 *
 * KEPT IN LOCKSTEP with the mobile catalog:
 *   mobile/lib/utils/languages.dart → kTargetLanguages mapped through
 *   geminiCodeFor (zh→zh-Hans, pt→pt-BR, otherwise identity).
 * Update both files together (mobile/test/languages_test.dart and
 * languages.test.ts here pin the parity).
 */
export const ALLOWED_TARGET_LANGUAGES: ReadonlySet<string> = new Set([
  "ar",
  "en",
  "es",
  "fr",
  "de",
  "hi",
  "zh-Hans",
  "ja",
  "ko",
  "tr",
  "pt-BR",
  "ru",
  "th",
  "id",
  "ms",
  "it",
  "nl",
  "ur",
  "fa",
  "he",
  "vi",
  "pl",
  "uk",
  "el",
  "sv",
]);
