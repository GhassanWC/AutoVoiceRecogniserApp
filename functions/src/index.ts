import { randomUUID } from "node:crypto";

import { Environment } from "@apple/app-store-server-library";
import { initializeApp } from "firebase-admin/app";
import { defineSecret, defineString } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

import { ALLOWED_TARGET_LANGUAGES } from "./languages.js";
import { TokenError, issueLiveTranslateToken } from "./token.js";
import {
  applyVerified,
  chargeSession,
  openSession,
  readEntitlement,
} from "./billing/store.js";
import { accessFor } from "./billing/entitlement.js";
import {
  BillingConfigError,
  BillingVerificationError,
  appleRootCertificates,
  verifyAppleTransaction,
  verifyGoogleSubscription,
} from "./billing/verify.js";

initializeApp();

const geminiApiKey = defineSecret("GEMINI_API_KEY");

// Apple App Store Server API credentials. Absent => Apple verification fails
// CLOSED; nothing is ever granted on an unconfigured backend.
const appleIssuerId = defineSecret("APPLE_ISSUER_ID");
const appleKeyId = defineSecret("APPLE_KEY_ID");
const applePrivateKey = defineSecret("APPLE_PRIVATE_KEY");
const appleBundleId = defineString("APPLE_BUNDLE_ID", {
  default: "com.ghassanalhattali.livetranslator",
});
const playPackageName = defineString("PLAY_PACKAGE_NAME", {
  default: "com.livetranslator.live_translator",
});

const REGION = "us-central1";

/** Client-visible code the app turns into the paywall. */
const OUT_OF_MINUTES = "out-of-minutes";

/**
 * Mints a short-lived, single-use Gemini Live API ephemeral token, and opens
 * the metered session that pays for it.
 *
 * This is the chokepoint for entitlement: with no allowance left there is no
 * token, so a hacked client cannot translate for free no matter what it
 * claims about its plan.
 */
export const createLiveTranslateToken = onCall(
  {
    enforceAppCheck: true,
    secrets: [geminiApiKey, appleIssuerId, appleKeyId, applePrivateKey],
    region: REGION,
    // Cost safety: this function only mints tokens; it must never scale wide.
    maxInstances: 5,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const target = request.data?.targetLanguageCode;
    if (typeof target !== "string" || !ALLOWED_TARGET_LANGUAGES.has(target)) {
      throw new HttpsError("invalid-argument", "Unsupported target language.");
    }
    // The metered session id is generated HERE, not accepted from the client:
    // a client that picked its own could reuse a closed one and translate for
    // free.
    const sessionId = randomUUID();

    const now = Date.now();
    // A subscriber whose period just rolled over should be able to start
    // straight away, so re-check the store before deciding they are out.
    await refreshLapsedFromStore(uid, await readEntitlement(uid, now), now);
    const opened = await openSession(uid, sessionId, now);
    if (opened === null) {
      // Out of minutes: the app shows the paywall.
      throw new HttpsError(
        "resource-exhausted",
        "Your included Live Translation minutes are used up.",
        { reason: OUT_OF_MINUTES },
      );
    }

    try {
      const issued = await issueLiveTranslateToken(target, {
        fetchFn: fetch,
        apiKey: geminiApiKey.value(),
      });
      // Safe telemetry only: NEVER log the ephemeral token or the API key.
      logger.info("createLiveTranslateToken issued", {
        uid,
        target,
        model: issued.model,
        expireTime: issued.expireTime,
        tokenLength: issued.token.length,
        remainingMinutes: opened.remainingMinutes,
      });
      return {
        ...issued,
        sessionId,
        remainingMinutes: opened.remainingMinutes,
      };
    } catch (error) {
      // The session never started, so close it rather than billing for it.
      await chargeSession(uid, sessionId, Date.now(), { close: true });
      if (error instanceof TokenError && error.kind === "quota") {
        throw new HttpsError(
          "resource-exhausted",
          "Translation capacity is currently reached. Please try again later.",
        );
      }
      logger.error("createLiveTranslateToken failed", {
        uid,
        error: error instanceof Error ? error.message : String(error),
      });
      throw new HttpsError("internal", "Could not start a translation session.");
    }
  },
);

/**
 * Bills elapsed session time and tells the client what is left. Called
 * periodically while listening, and once with `close` when the session ends.
 * Time is measured on the SERVER between calls, so the client cannot
 * under-report.
 */
export const meterLiveTranslateSession = onCall(
  { enforceAppCheck: true, region: REGION, maxInstances: 20 },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const sessionId = request.data?.sessionId;
    if (typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "A session id is required.");
    }
    const close = request.data?.close === true;
    const result = await chargeSession(
      request.auth.uid,
      sessionId,
      Date.now(),
      { close },
    );
    return result;
  },
);

/**
 * Verifies a purchase with Apple or Google and applies the resulting
 * entitlement.
 *
 * The client sends ONLY an opaque handle. The plan comes from what the store
 * says about that handle — a client claiming "pro" gets nothing.
 */
export const verifySubscriptionPurchase = onCall(
  {
    enforceAppCheck: true,
    secrets: [appleIssuerId, appleKeyId, applePrivateKey],
    region: REGION,
    maxInstances: 10,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const store = request.data?.store;
    const now = Date.now();

    try {
      if (store === "apple") {
        const transactionId = request.data?.transactionId;
        if (typeof transactionId !== "string" || transactionId.length === 0) {
          throw new HttpsError("invalid-argument", "transactionId is required.");
        }
        const verified = await verifyAppleTransaction(transactionId, {
          issuerId: appleIssuerId.value(),
          keyId: appleKeyId.value(),
          privateKey: applePrivateKey.value(),
          bundleId: appleBundleId.value(),
          // Production first, then sandbox for TestFlight. Never taken from
          // the client, which would otherwise pick the easier environment.
          environment: Environment.PRODUCTION,
          rootCertificates: appleRootCertificates(),
        });
        const entitlement = await applyVerified(uid, verified, now);
        logger.info("apple purchase verified", { uid, plan: entitlement.plan });
        return summarize(entitlement, now);
      }

      if (store === "google") {
        const purchaseToken = request.data?.purchaseToken;
        if (typeof purchaseToken !== "string" || purchaseToken.length === 0) {
          throw new HttpsError("invalid-argument", "purchaseToken is required.");
        }
        const verified = await verifyGoogleSubscription(purchaseToken, {
          packageName: playPackageName.value(),
        });
        const entitlement = await applyVerified(uid, verified, now);
        logger.info("play purchase verified", { uid, plan: entitlement.plan });
        return summarize(entitlement, now);
      }

      throw new HttpsError("invalid-argument", "Unknown store.");
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      if (error instanceof BillingConfigError) {
        // Fail closed and say so, rather than granting anything.
        logger.error("billing not configured", { message: error.message });
        throw new HttpsError(
          "failed-precondition",
          "Purchases are not available yet. Please try again later.",
        );
      }
      if (error instanceof BillingVerificationError) {
        logger.warn("purchase verification rejected", {
          uid,
          message: error.message,
        });
        throw new HttpsError("permission-denied", "Purchase could not be verified.");
      }
      logger.error("verifySubscriptionPurchase failed", {
        uid,
        error: error instanceof Error ? error.message : String(error),
      });
      throw new HttpsError("internal", "Could not verify the purchase.");
    }
  },
);

/** The app's read of its own entitlement, straight from the server. */
export const getEntitlement = onCall(
  {
    enforceAppCheck: true,
    secrets: [appleIssuerId, appleKeyId, applePrivateKey],
    region: REGION,
    maxInstances: 10,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const now = Date.now();
    const uid = request.auth.uid;
    const stored = await readEntitlement(uid, now);
    return summarize(await refreshLapsedFromStore(uid, stored, now), now);
  },
);

/**
 * Re-asks Apple or Google about a subscription whose stored period has run
 * out, so a renewal extends access without waiting for the user to open the
 * paywall — and an expiry or refund is noticed without one either.
 *
 * Bounded on purpose: it only fires once the stored period has actually
 * lapsed, and never for an account that has no store handle on file. A
 * failure leaves the stored entitlement exactly as it was, so a store outage
 * neither grants nor removes anything.
 */
async function refreshLapsedFromStore(
  uid: string,
  entitlement: Awaited<ReturnType<typeof readEntitlement>>,
  nowMs: number,
) {
  const handle = entitlement.storeHandle;
  if (
    handle === null ||
    entitlement.currentPeriodEnd === null ||
    nowMs < entitlement.currentPeriodEnd
  ) {
    return entitlement;
  }
  try {
    const verified =
      entitlement.store === "apple"
        ? await verifyAppleTransaction(handle, {
            issuerId: appleIssuerId.value(),
            keyId: appleKeyId.value(),
            privateKey: applePrivateKey.value(),
            bundleId: appleBundleId.value(),
            environment: Environment.PRODUCTION,
            rootCertificates: appleRootCertificates(),
          })
        : await verifyGoogleSubscription(handle, {
            packageName: playPackageName.value(),
          });
    return await applyVerified(uid, verified, nowMs);
  } catch (error) {
    logger.warn("could not re-check a lapsed subscription", {
      uid,
      store: entitlement.store,
      error: error instanceof Error ? error.message : String(error),
    });
    return entitlement;
  }
}

function summarize(
  entitlement: Awaited<ReturnType<typeof readEntitlement>>,
  nowMs: number,
) {
  const access = accessFor(entitlement, nowMs);
  return {
    plan: access.plan,
    subscriptionStatus: entitlement.subscriptionStatus,
    store: entitlement.store,
    storeProductId: entitlement.storeProductId,
    currentPeriodStart: entitlement.currentPeriodStart,
    currentPeriodEnd: entitlement.currentPeriodEnd,
    minutesAllowance: entitlement.minutesAllowance,
    minutesUsed: entitlement.minutesUsed,
    freeMinutesUsed: entitlement.freeMinutesUsed,
    remainingMinutes: access.remainingMinutes,
    allowanceSource: access.source,
    allowed: access.allowed,
    entitlementUpdatedAt: entitlement.entitlementUpdatedAt,
  };
}
