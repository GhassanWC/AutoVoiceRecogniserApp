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

/** How long the token may keep an open session sending messages. */
const TOKEN_TTL_MINUTES = 30;
/** Window in which the single new session must be started. */
const NEW_SESSION_TTL_SECONDS = 60;

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
}

export interface LiveTranslateToken {
  token: string;
  model: string;
  expireTime: string;
}

/** The exact constraint payload sent to auth_tokens (exported for tests). */
export function tokenRequestBody(
  targetLanguageCode: string,
  nowMs: number,
): Record<string, unknown> {
  return {
    uses: 1,
    expireTime: new Date(nowMs + TOKEN_TTL_MINUTES * 60_000).toISOString(),
    newSessionExpireTime: new Date(
      nowMs + NEW_SESSION_TTL_SECONDS * 1_000,
    ).toISOString(),
    liveConnectConstraints: {
      model: MODEL,
      config: {
        responseModalities: ["AUDIO"],
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        // Lets a dropped connection resume the same session on this token.
        sessionResumption: {},
        translationConfig: {
          targetLanguageCode,
          echoTargetLanguage: true,
        },
      },
    },
  };
}

export async function issueLiveTranslateToken(
  targetLanguageCode: string,
  deps: TokenDeps,
): Promise<LiveTranslateToken> {
  const nowMs = (deps.now ?? Date.now)();
  const body = tokenRequestBody(targetLanguageCode, nowMs);
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
  };
}
