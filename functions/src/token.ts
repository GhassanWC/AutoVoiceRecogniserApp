/**
 * Gemini Live API ephemeral token minting.
 *
 * The permanent GEMINI_API_KEY exists ONLY here (injected from Secret
 * Manager); clients receive a short-lived, single-use token whose
 * liveConnectConstraints lock the model AND the full Live Translate config —
 * including translationConfig — so a client cannot repurpose the token for
 * anything but translating into the language it asked for.
 */

export const MODEL = "models/gemini-3.5-live-translate-preview";
export const AUTH_TOKENS_URL =
  "https://generativelanguage.googleapis.com/v1beta/auth_tokens";

/**
 * How long one lease may keep a session open.
 *
 * This is a SECURITY AND COST lease, not a billing quantity. A leaked or
 * stolen token is worth at most five minutes of Gemini time, and a session
 * that outlives its lease renews transparently — the app asks for another
 * token, which re-checks the account's entitlement before it is issued.
 *
 * It says nothing about what the customer pays. Customer usage is translated
 * speech only, so five minutes of silence under a five-minute lease still
 * costs zero.
 */
export const MAX_TOKEN_LEASE_MINUTES = 5;
const TOKEN_TTL_MINUTES = MAX_TOKEN_LEASE_MINUTES;
/** Window in which the single new session must be started. */
const NEW_SESSION_TTL_SECONDS = 60;

/**
 * Speech detection tuned for a ROOM rather than a phone held to a face.
 *
 * Sayvo is an ambient translator: somebody across a table or three metres away
 * is the normal case, not the edge case. Gemini's own automatic activity
 * detection is what decides whether that speech becomes a turn at all, and at
 * its default sensitivity a quiet or distant voice frequently is not detected
 * — the audio arrives, and nothing happens.
 *
 * Field meanings are quoted from the v1beta discovery document (the
 * machine-readable API contract), because the prose guide describes
 * `prefixPaddingMs` the other way round — as OpenAI's identically-named
 * look-back field. The contract is what this API implements:
 *
 *  - `prefixPaddingMs`: "The required duration of detected speech before
 *    start-of-speech is committed. The LOWER this value, the more sensitive
 *    the start-of-speech detection is and shorter speech can be recognized."
 *    20 ms asks for almost nothing, which is what keeps the first quiet word.
 *    Raising it would make quiet speech HARDER to detect, not easier.
 *  - `silenceDurationMs`: "The required duration of detected non-speech
 *    before end-of-speech is committed." A distant speaker dips below the
 *    threshold mid-sentence; 800 ms stops that being read as "finished".
 *  - START_SENSITIVITY_HIGH: "detect the start of speech more often".
 *  - END_SENSITIVITY_LOW: "ends speech less often".
 *
 * All four are already at their most sensitive setting, which is why the
 * far-field work continues in the two fields below rather than here.
 */
export const FAR_FIELD_ACTIVITY_DETECTION = {
  disabled: false,
  startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
  endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
  prefixPaddingMs: 20,
  silenceDurationMs: 800,
} as const;

/**
 * What the model is given, and what a new speaker does to a translation in
 * flight. Both default the wrong way for an ambient translator.
 *
 * `turnCoverage` (discovery document): the default for current models is
 * TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO, where "audio activity means
 * speech and EXCLUDES silence" — so the turn contains only what the VAD
 * carved out, and a quiet onset the VAD commits late is simply not in it.
 * TURN_INCLUDES_ALL_INPUT "includes all realtime input since the last turn,
 * including inactivity", which hands the model the continuous stream Sayvo
 * is already sending and lets IT decide where the speech starts. That is the
 * architectural point: the phone should not pre-decide what is speech.
 *
 * `activityHandling`: the default START_OF_ACTIVITY_INTERRUPTS is barge-in —
 * "the model's current response will be cut-off in the moment of the
 * interruption". In a room, the second speaker starting is the NORMAL case,
 * and cutting the first speaker's translation off mid-sentence loses text the
 * user needed. NO_INTERRUPTION lets each translation finish.
 */
export const FAR_FIELD_TURN_COVERAGE = "TURN_INCLUDES_ALL_INPUT";
export const FAR_FIELD_ACTIVITY_HANDLING = "NO_INTERRUPTION";

/**
 * The realtimeInputConfig the token locks in — and the SAME object the app is
 * told to send in its own setup frame, so the two can never disagree. Returns
 * undefined when far-field detection is switched off, which restores exactly
 * the previous behaviour.
 */
export function farFieldRealtimeInputConfig(
  enabled: boolean,
): Record<string, unknown> | undefined {
  return enabled
    ? {
        automaticActivityDetection: { ...FAR_FIELD_ACTIVITY_DETECTION },
        turnCoverage: FAR_FIELD_TURN_COVERAGE,
        activityHandling: FAR_FIELD_ACTIVITY_HANDLING,
      }
    : undefined;
}

export type TokenErrorKind = "quota" | "upstream";

export class TokenError extends Error {
  constructor(
    public readonly kind: TokenErrorKind,
    message?: string,
  ) {
    super(message ?? kind);
    this.name = "TokenError";
  }
}

export interface TokenDeps {
  fetchFn: typeof fetch;
  apiKey: string;
  now?: () => number;
  /** Far-field speech detection; off restores the previous default VAD. */
  farField?: boolean;
}

export interface LiveTranslateToken {
  token: string;
  model: string;
  expireTime: string;
  /**
   * Echoed to the app so its setup frame matches the token constraint
   * exactly. The client never composes this itself.
   */
  realtimeInputConfig?: Record<string, unknown>;
}

/**
 * The exact payload sent to auth_tokens (exported for tests).
 *
 * Shape verified against the live v1beta discovery document (AuthToken
 * schema) and a real 200 mint on 2026-09-15: the API has NO
 * `liveConnectConstraints` field — the locked configuration goes in
 * `bidiGenerateContentSetup` (the same message as the WebSocket `setup`
 * frame), flat in the body (never wrapped in `{"authToken": ...}`).
 * With no fieldMask and this setup present, the effective setup comes
 * entirely from the token — the client's own setup frame cannot loosen it.
 *
 * Placement matters: `translationConfig` and `responseModalities` live in
 * `generationConfig`; the transcription configs and `sessionResumption`
 * sit at the setup level. Unknown or misplaced fields are rejected with
 * 400 INVALID_ARGUMENT "Unknown name ... at 'auth_token'".
 */
export function tokenRequestBody(
  targetLanguageCode: string,
  nowMs: number,
  farField = true,
): Record<string, unknown> {
  const realtimeInputConfig = farFieldRealtimeInputConfig(farField);
  return {
    uses: 1,
    expireTime: new Date(nowMs + TOKEN_TTL_MINUTES * 60_000).toISOString(),
    newSessionExpireTime: new Date(
      nowMs + NEW_SESSION_TTL_SECONDS * 1_000,
    ).toISOString(),
    bidiGenerateContentSetup: {
      model: MODEL,
      generationConfig: {
        responseModalities: ["AUDIO"],
        translationConfig: {
          targetLanguageCode,
          echoTargetLanguage: true,
        },
      },
      inputAudioTranscription: {},
      outputAudioTranscription: {},
      // Room-tuned speech detection. The token LOCKS it, so a tampered client
      // cannot quietly widen or disable it.
      ...(realtimeInputConfig ? { realtimeInputConfig } : {}),
      // Lets a dropped connection resume the same session on this token.
      sessionResumption: {},
    },
  };
}

export async function issueLiveTranslateToken(
  targetLanguageCode: string,
  deps: TokenDeps,
): Promise<LiveTranslateToken> {
  const nowMs = (deps.now ?? Date.now)();
  const farField = deps.farField ?? true;
  const body = tokenRequestBody(targetLanguageCode, nowMs, farField);
  const response = await deps.fetchFn(AUTH_TOKENS_URL, {
    method: "POST",
    headers: {
      "x-goog-api-key": deps.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (response.status === 429) {
    throw new TokenError("quota", "Gemini quota exceeded");
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new TokenError(
      "upstream",
      `auth_tokens ${response.status}: ${detail.slice(0, 500)}`,
    );
  }

  const json = (await response.json()) as { name?: unknown };
  if (typeof json.name !== "string" || json.name.length === 0) {
    throw new TokenError("upstream", "auth_tokens response missing token name");
  }
  return {
    token: json.name,
    model: MODEL,
    expireTime: body.expireTime as string,
    // Handed to the app so its setup frame matches this token exactly.
    realtimeInputConfig: farFieldRealtimeInputConfig(farField),
  };
}
