import { describe, expect, it } from "vitest";

import { ALLOWED_TARGET_LANGUAGES } from "./languages.js";

// Fixture copied from mobile/lib/utils/languages.dart (kTargetLanguages, each
// row's geminiCode). mobile/test/languages_test.dart carries the mirror-image
// test — update BOTH when the catalog changes.
const MOBILE_CATALOG_GEMINI_CODES = [
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
];

describe("ALLOWED_TARGET_LANGUAGES", () => {
  it("matches the mobile target-language catalog exactly", () => {
    expect(new Set(MOBILE_CATALOG_GEMINI_CODES)).toEqual(
      new Set(ALLOWED_TARGET_LANGUAGES),
    );
  });

  it("covers the languages gemini-3.5-live-translate-preview documents", () => {
    // The model's own table, not a product shortlist. A smaller number here
    // means Sayvo is refusing languages the model can actually translate.
    expect(ALLOWED_TARGET_LANGUAGES.size).toBe(78);
  });

  it("accepts Bengali", () => {
    // The exact check that used to reject it: bn reached this set and was not
    // in it, so createLiveTranslateToken answered invalid-argument.
    expect(ALLOWED_TARGET_LANGUAGES.has("bn")).toBe(true);
  });

  it("accepts the other major languages that used to be refused", () => {
    for (const code of [
      "pa", "mr", "ta", "te", "gu", "kn", "ml", "fil",
      "sw", "ha", "am", "my", "km", "ne", "si", "ro",
      "hu", "cs", "da", "fi", "nb", "zh-Hant", "pt-PT",
    ]) {
      expect(ALLOWED_TARGET_LANGUAGES.has(code), code).toBe(true);
    }
  });

  it("keeps every language that already worked", () => {
    for (const code of [
      "ar", "en", "es", "fr", "de", "hi", "zh-Hans", "ja", "ko", "tr",
      "pt-BR", "ru", "th", "id", "ms", "it", "nl", "ur", "fa", "he",
      "vi", "pl", "uk", "el", "sv",
    ]) {
      expect(ALLOWED_TARGET_LANGUAGES.has(code), code).toBe(true);
    }
  });

  it("uses BCP-47 forms for Chinese and Portuguese", () => {
    expect(ALLOWED_TARGET_LANGUAGES.has("zh-Hans")).toBe(true);
    expect(ALLOWED_TARGET_LANGUAGES.has("zh-Hant")).toBe(true);
    expect(ALLOWED_TARGET_LANGUAGES.has("pt-BR")).toBe(true);
    expect(ALLOWED_TARGET_LANGUAGES.has("pt-PT")).toBe(true);
    // The app maps zh → zh-Hans and pt → pt-BR before it ever gets here.
    expect(ALLOWED_TARGET_LANGUAGES.has("zh")).toBe(false);
    expect(ALLOWED_TARGET_LANGUAGES.has("pt")).toBe(false);
  });

  it("is still a closed set", () => {
    // It is widened by adding languages, never by dropping the check: this
    // value goes into a server-minted token, so an arbitrary client string
    // must not reach it.
    expect(ALLOWED_TARGET_LANGUAGES.has("")).toBe(false);
    expect(ALLOWED_TARGET_LANGUAGES.has("en; DROP")).toBe(false);
    expect(ALLOWED_TARGET_LANGUAGES.has("../../etc/passwd")).toBe(false);
    expect(ALLOWED_TARGET_LANGUAGES.has("klingon")).toBe(false);
  });
});
