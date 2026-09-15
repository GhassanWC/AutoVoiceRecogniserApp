import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

import { ALLOWED_TARGET_LANGUAGES } from "./languages.js";
import { TokenError, issueLiveTranslateToken } from "./token.js";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

/**
 * Mints a short-lived, single-use Gemini Live API ephemeral token,
 * constrained to the Live Translate configuration for the requested target
 * language. Requires a signed-in Firebase user AND a valid App Check token.
 *
 * The client then connects DIRECTLY to the Gemini Live WebSocket with this
 * token — microphone audio never flows through Firebase.
 */
export const createLiveTranslateToken = onCall(
  {
    enforceAppCheck: true,
    secrets: [geminiApiKey],
    region: "us-central1",
    // Cost safety: this function only mints tokens; it must never scale wide.
    maxInstances: 5,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const target = request.data?.targetLanguageCode;
    if (typeof target !== "string" || !ALLOWED_TARGET_LANGUAGES.has(target)) {
      throw new HttpsError("invalid-argument", "Unsupported target language.");
    }
    try {
      const issued = await issueLiveTranslateToken(target, {
        fetchFn: fetch,
        apiKey: geminiApiKey.value(),
      });
      // Safe telemetry only: NEVER log the ephemeral token or the API key.
      logger.info("createLiveTranslateToken issued", {
        uid: request.auth.uid,
        target,
        model: issued.model,
        expireTime: issued.expireTime,
        tokenLength: issued.token.length,
      });
      return issued;
    } catch (error) {
      if (error instanceof TokenError && error.kind === "quota") {
        throw new HttpsError(
          "resource-exhausted",
          "Translation capacity is currently reached. Please try again later.",
        );
      }
      logger.error("createLiveTranslateToken failed", {
        uid: request.auth.uid,
        error: error instanceof Error ? error.message : String(error),
      });
      throw new HttpsError("internal", "Could not start a translation session.");
    }
  },
);
