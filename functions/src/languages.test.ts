import { describe, expect, it } from "vitest";

import { ALLOWED_TARGET_LANGUAGES } from "./languages.js";

// Fixture copied from mobile/lib/utils/languages.dart (kTargetLanguages
// mapped through geminiCodeFor). mobile/test/languages_test.dart carries the
// mirror-image test — update BOTH when the catalog changes.
const MOBILE_CATALOG_GEMINI_CODES = [
  "ar", "en", "es", "fr", "de", "hi", "zh-Hans", "ja", "ko", "tr",
  "pt-BR", "ru", "th", "id", "ms", "it", "nl", "ur", "fa", "he",
  "vi", "pl", "uk", "el", "sv",
];

describe("ALLOWED_TARGET_LANGUAGES", () => {
  it("matches the mobile target-language catalog exactly", () => {
    expect(new Set(MOBILE_CATALOG_GEMINI_CODES)).toEqual(
      new Set(ALLOWED_TARGET_LANGUAGES),
    );
  });

  it("uses BCP-47 forms for Chinese and Portuguese", () => {
    expect(ALLOWED_TARGET_LANGUAGES.has("zh-Hans")).toBe(true);
    expect(ALLOWED_TARGET_LANGUAGES.has("pt-BR")).toBe(true);
    expect(ALLOWED_TARGET_LANGUAGES.has("zh")).toBe(false);
    expect(ALLOWED_TARGET_LANGUAGES.has("pt")).toBe(false);
  });
});
