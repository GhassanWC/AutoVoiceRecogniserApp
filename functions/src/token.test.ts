import { describe, expect, it } from "vitest";

import {
  AUTH_TOKENS_URL,
  FAR_FIELD_ACTIVITY_DETECTION,
  MAX_TOKEN_LEASE_MINUTES,
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

describe("the lease a token grants", () => {
  it("never runs longer than five minutes", () => {
    expect(MAX_TOKEN_LEASE_MINUTES).toBeLessThanOrEqual(5);
    const body = tokenRequestBody("ar", NOW);
    const lease = Date.parse(body.expireTime as string) - NOW;
    expect(lease).toBeGreaterThan(0);
    expect(lease).toBeLessThanOrEqual(5 * 60_000);
  });

  it("is single-use, so one token opens exactly one connection", () => {
    expect(tokenRequestBody("ar", NOW).uses).toBe(1);
  });

  it("gives an even shorter window to actually start the session", () => {
    const body = tokenRequestBody("ar", NOW);
    const startWindow = Date.parse(body.newSessionExpireTime as string) - NOW;
    expect(startWindow).toBeLessThan(
      Date.parse(body.expireTime as string) - NOW,
    );
  });

  it("is a cost and security bound, not a billing unit", () => {
    // Nothing about the lease reaches the customer's allowance: usage is
    // translated speech, measured and charged entirely elsewhere. This test
    // exists to pin the intent — a five-minute lease spent in silence is
    // worth zero, which usage.test.ts and store.test.ts prove.
    const body = tokenRequestBody("ar", NOW);
    expect(Object.keys(body)).not.toContain("minutes");
    expect(Object.keys(body)).not.toContain("allowance");
  });
});

describe("room-tuned speech detection", () => {
  function setupOf(body: Record<string, unknown>) {
    return body.bidiGenerateContentSetup as Record<string, unknown>;
  }

  it("gives the model the whole stream, not only what its VAD carved out", () => {
    // The default (TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO) means, per the
    // discovery document, that "audio activity means speech and excludes
    // silence" — so a quiet onset the VAD commits late is not in the turn at
    // all. This is the setting that lets the MODEL decide where speech began
    // rather than the activity detector deciding for it.
    const config = setupOf(tokenRequestBody("ar", NOW))
      .realtimeInputConfig as Record<string, unknown>;
    expect(config.turnCoverage).toBe("TURN_INCLUDES_ALL_INPUT");
  });

  it("lets a translation finish when the next person starts talking", () => {
    // The default is barge-in: a new speaker cuts the previous speaker's
    // translation off mid-sentence. In a room that is the normal case, and
    // the text the user loses is text they needed.
    const config = setupOf(tokenRequestBody("ar", NOW))
      .realtimeInputConfig as Record<string, unknown>;
    expect(config.activityHandling).toBe("NO_INTERRUPTION");
  });

  it("asks Gemini to be sensitive about where speech STARTS", () => {
    const detection = (
      setupOf(tokenRequestBody("ar", NOW)).realtimeInputConfig as Record<
        string,
        unknown
      >
    ).automaticActivityDetection as Record<string, unknown>;

    expect(detection.disabled).toBe(false);
    expect(detection.startOfSpeechSensitivity).toBe("START_SENSITIVITY_HIGH");
    // Less eager to call an utterance finished, because a distant speaker
    // dips below the threshold mid-sentence.
    expect(detection.endOfSpeechSensitivity).toBe("END_SENSITIVITY_LOW");
    // prefixPaddingMs is the speech REQUIRED before a start commits, so a low
    // value is the sensitive one — this is the field most easily read
    // backwards.
    expect(detection.prefixPaddingMs).toBeLessThanOrEqual(100);
    // silenceDurationMs is the silence required before an end commits, so a
    // high value tolerates the gaps in quiet speech.
    expect(detection.silenceDurationMs).toBeGreaterThanOrEqual(500);
  });

  it("uses only fields the v1beta AutomaticActivityDetection schema defines", () => {
    // Verified against the live discovery document. An unknown field here is
    // rejected by auth_tokens with 400 INVALID_ARGUMENT, which would stop the
    // app minting tokens at all.
    const detection = FAR_FIELD_ACTIVITY_DETECTION as Record<string, unknown>;
    expect(Object.keys(detection).sort()).toEqual([
      "disabled",
      "endOfSpeechSensitivity",
      "prefixPaddingMs",
      "silenceDurationMs",
      "startOfSpeechSensitivity",
    ]);
  });

  it("uses only fields the v1beta RealtimeInputConfig schema defines", () => {
    // Same hazard one level up: turnCoverage and activityHandling are real
    // RealtimeInputConfig fields, and anything else here would break minting.
    const config = setupOf(tokenRequestBody("ar", NOW))
      .realtimeInputConfig as Record<string, unknown>;
    expect(Object.keys(config).sort()).toEqual([
      "activityHandling",
      "automaticActivityDetection",
      "turnCoverage",
    ]);
    // And the values must be enum members the schema lists.
    expect([
      "TURN_COVERAGE_UNSPECIFIED",
      "TURN_INCLUDES_ONLY_ACTIVITY",
      "TURN_INCLUDES_ALL_INPUT",
      "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO",
    ]).toContain(config.turnCoverage);
    expect([
      "ACTIVITY_HANDLING_UNSPECIFIED",
      "START_OF_ACTIVITY_INTERRUPTS",
      "NO_INTERRUPTION",
    ]).toContain(config.activityHandling);
  });

  it("locks the SAME config into the token that the app is told to send",
    async () => {
      // The app echoes this verbatim in its setup frame. If the two could
      // differ, the constrained session would be rejected.
      const { fetchFn } = fakeFetch(200, { name: "auth_tokens/abc" });
      const issued = await issueLiveTranslateToken("ar", {
        fetchFn,
        apiKey: "SECRET",
        now: () => NOW,
      });
      expect(issued.realtimeInputConfig).toEqual(
        setupOf(tokenRequestBody("ar", NOW)).realtimeInputConfig,
      );
    });

  it("the kill switch removes it from the token AND from the app", async () => {
    const body = tokenRequestBody("ar", NOW, false);
    expect(setupOf(body).realtimeInputConfig).toBeUndefined();

    const { calls, fetchFn } = fakeFetch(200, { name: "auth_tokens/abc" });
    const issued = await issueLiveTranslateToken("ar", {
      fetchFn,
      apiKey: "SECRET",
      now: () => NOW,
      farField: false,
    });
    expect(issued.realtimeInputConfig).toBeUndefined();
    const sent = JSON.parse(String(calls[0].init.body));
    expect(sent.bidiGenerateContentSetup.realtimeInputConfig).toBeUndefined();
  });

  it("leaves everything else about the token untouched", () => {
    const withFarField = setupOf(tokenRequestBody("ar", NOW));
    const without = setupOf(tokenRequestBody("ar", NOW, false));
    for (const key of ["model", "generationConfig", "inputAudioTranscription"]) {
      expect(withFarField[key]).toEqual(without[key]);
    }
  });
});

describe("tokenRequestBody", () => {
  // Pins the exact v1beta AuthToken request shape, verified against the
  // live discovery document and a real 200 mint — if Google changes the
  // auth_tokens contract, this fails loudly instead of silently drifting.
  it("locks the full Live Translate setup server-side", () => {
    const body = tokenRequestBody("ar", NOW);
    expect(body).toEqual({
      uses: 1,
      expireTime: "2026-09-14T10:05:00.000Z",
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
        realtimeInputConfig: {
          turnCoverage: "TURN_INCLUDES_ALL_INPUT",
          activityHandling: "NO_INTERRUPTION",
          automaticActivityDetection: {
            disabled: false,
            startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
            endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
            prefixPaddingMs: 20,
            silenceDurationMs: 800,
          },
        },
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
      expireTime: "2026-09-14T10:05:00.000Z",
      // Handed on to the app so its setup frame matches the token.
      realtimeInputConfig: {
        turnCoverage: "TURN_INCLUDES_ALL_INPUT",
        activityHandling: "NO_INTERRUPTION",
        automaticActivityDetection: {
          disabled: false,
          startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
          endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
          prefixPaddingMs: 20,
          silenceDurationMs: 800,
        },
      },
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
