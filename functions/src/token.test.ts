import { describe, expect, it } from "vitest";

import {
  AUTH_TOKENS_URL,
  MODEL,
  TokenError,
  issueLiveTranslateToken,
  tokenRequestBody,
} from "./token.js";

const NOW = Date.parse("2026-09-14T10:00:00Z");

function fakeFetch(
  status: number,
  body: unknown,
): { calls: { url: string; init: RequestInit }[]; fetchFn: typeof fetch } {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchFn = (async (url: unknown, init?: unknown) => {
    calls.push({ url: String(url), init: (init ?? {}) as RequestInit });
    return new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
    });
  }) as typeof fetch;
  return { calls, fetchFn };
}

describe("tokenRequestBody", () => {
  // Pins the exact v1beta AuthToken request shape, verified against the
  // live discovery document and a real 200 mint — if Google changes the
  // auth_tokens contract, this fails loudly instead of silently drifting.
  it("locks the full Live Translate setup server-side", () => {
    const body = tokenRequestBody("ar", NOW);
    expect(body).toEqual({
      uses: 1,
      expireTime: "2026-09-14T10:30:00.000Z",
      newSessionExpireTime: "2026-09-14T10:01:00.000Z",
      bidiGenerateContentSetup: {
        model: "models/gemini-3.5-live-translate-preview",
        generationConfig: {
          responseModalities: ["AUDIO"],
          translationConfig: {
            targetLanguageCode: "ar",
            echoTargetLanguage: true,
          },
        },
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        sessionResumption: {},
      },
    });
  });

  it("sends no fields the auth_tokens API rejects", () => {
    const body = tokenRequestBody("ar", NOW);
    // The API has no `liveConnectConstraints` and no `authToken` wrapper —
    // both produce 400 INVALID_ARGUMENT "Unknown name ... at 'auth_token'".
    expect(body).not.toHaveProperty("authToken");
    expect(body).not.toHaveProperty("liveConnectConstraints");
    expect(Object.keys(body).sort()).toEqual([
      "bidiGenerateContentSetup",
      "expireTime",
      "newSessionExpireTime",
      "uses",
    ]);
    // Placement pins: translationConfig belongs INSIDE generationConfig;
    // transcription configs at setup level (not in generationConfig).
    const setup = body.bidiGenerateContentSetup as Record<string, unknown>;
    const generation = setup.generationConfig as Record<string, unknown>;
    expect(generation).toHaveProperty("translationConfig");
    expect(generation).not.toHaveProperty("inputAudioTranscription");
    expect(setup).toHaveProperty("inputAudioTranscription");
    expect(setup).toHaveProperty("outputAudioTranscription");
  });
});

describe("issueLiveTranslateToken", () => {
  it("POSTs to auth_tokens with the API key header and returns the token", async () => {
    const { calls, fetchFn } = fakeFetch(200, { name: "auth_tokens/abc123" });
    const result = await issueLiveTranslateToken("th", {
      fetchFn,
      apiKey: "SECRET",
      now: () => NOW,
    });
    expect(result).toEqual({
      token: "auth_tokens/abc123",
      model: MODEL,
      expireTime: "2026-09-14T10:30:00.000Z",
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(AUTH_TOKENS_URL);
    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["x-goog-api-key"]).toBe("SECRET");
    const sent = JSON.parse(String(calls[0].init.body));
    expect(
      sent.bidiGenerateContentSetup.generationConfig.translationConfig,
    ).toEqual({
      targetLanguageCode: "th",
      echoTargetLanguage: true,
    });
  });

  it("maps 429 to a quota TokenError", async () => {
    const { fetchFn } = fakeFetch(429, { error: "rate limited" });
    await expect(
      issueLiveTranslateToken("ar", { fetchFn, apiKey: "k", now: () => NOW }),
    ).rejects.toMatchObject({ kind: "quota" });
  });

  it("maps other failures to upstream TokenError", async () => {
    const { fetchFn } = fakeFetch(500, "boom");
    await expect(
      issueLiveTranslateToken("ar", { fetchFn, apiKey: "k", now: () => NOW }),
    ).rejects.toMatchObject({ kind: "upstream" });
  });

  it("rejects a response without a token name", async () => {
    const { fetchFn } = fakeFetch(200, { notName: true });
    const error = await issueLiveTranslateToken("ar", {
      fetchFn,
      apiKey: "k",
      now: () => NOW,
    }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TokenError);
    expect((error as TokenError).kind).toBe("upstream");
  });
});
