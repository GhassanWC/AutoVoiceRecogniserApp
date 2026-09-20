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
 * Field meanings are from the v1beta discovery document, and two of them read
 * the opposite way round to what the names suggest:
 *  - `prefixPaddingMs` is the duration of speech REQUIRED before a start is
 *    committed, so a LOW value is the sensitive one. 20 ms barely asks for
 *    anything, which is what keeps the first quiet word.
 *  - `silenceDurationMs` is the silence required before an end is committed,
 *    so a HIGH value tolerates longer gaps. A distant speaker dips below the
 *    threshold mid-sentence; 800 ms stops that being read as "finished".
 *  - START_SENSITIVITY_HIGH detects speech starts more often.
 *  - END_SENSITIVITY_LOW is less eager to declare speech over.
 *
 * These are a calibrated STARTING POINT, to be trimmed against real device
 * logs — see the far-field acceptance matrix in the report.
 */
export const FAR_FIELD_ACTIVITY_DETECTION = {
  disabled: false,
  startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
  endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
  prefixPaddingMs: 20,
  silenceDurationMs: 800,
} as const;

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
    ? { automaticActivityDetection: { ...FAR_FIELD_ACTIVITY_DETECTION } }
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
