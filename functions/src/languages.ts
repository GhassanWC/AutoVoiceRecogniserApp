/**
 * Server-side validation set for the Gemini Live Translate
 * `targetLanguageCode`, in the BCP-47 form the API expects.
 *
 * This is NOT a product shortlist — it is the full set of languages
 * `gemini-3.5-live-translate-preview` documents support for. It stays a closed
 * set because the value is written straight into a SERVER-MINTED token's
 * `bidiGenerateContentSetup`: validating it here is what stops a tampered
 * client putting an arbitrary string inside a credential this server signs,
 * and what turns an unsupported language into a clear rejection instead of an
 * opaque 400 from the model. Widen it by adding languages, never by dropping
 * the check.
 *
 * The SOURCE language is deliberately absent: the model detects it per
 * utterance and is never told what to listen for, so nothing here can limit
 * what Sayvo can HEAR — only what it can translate INTO.
 *
 * KEPT IN LOCKSTEP with the mobile catalog:
 *   mobile/lib/utils/languages.dart → kTargetLanguages, each row's
 *   geminiCode (equal to its code unless the model spells it differently).
 * Update both files together — mobile/test/languages_test.dart and
 * languages.test.ts here pin the parity in both directions.
 */
export const ALLOWED_TARGET_LANGUAGES: ReadonlySet<string> = new Set([
  "ar", "en", "es", "fr", "de", "hi", "zh-Hans", "ja",
  "ko", "tr", "pt-BR", "ru", "th", "id", "ms", "it",
  "nl", "ur", "fa", "he", "vi", "pl", "uk", "el",
  "sv", "af", "ak", "sq", "am", "hy", "az", "eu",
  "be", "bn", "bg", "my", "ca", "zh-Hant", "hr", "cs",
  "da", "et", "fil", "fi", "gl", "ka", "gu", "ha",
  "hu", "is", "jv", "kn", "kk", "km", "rw", "lo",
  "lv", "lt", "mk", "ml", "mr", "mn", "ne", "nb",
  "pt-PT", "pa", "ro", "sr", "sd", "si", "sk", "sl",
  "su", "sw", "ta", "te", "uz", "zu",
]);
